using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace MiZhong.Core;
public record Options {
    public bool Recursive { get; init; } = true;
    public bool Hidden { get; init; }
    public long Minimum { get; init; } = 1;
    public long Maximum { get; init; } = long.MaxValue;
    public string[] Excluded { get; init; } = [];
    public string[] Extensions { get; init; } = [];
    public int LocalWorkers { get; init; } = 4;
    public int NetworkWorkers { get; init; } = 2;
    public string[] NonRecursiveRoots { get; init; } = [];
}
public record Entry(string Path, long Size, DateTime Modified, string Identity, bool Network);
public record Group(string Hash, List<Entry> Files) {
    public long Reclaimable => Files.Count > 1 ? Files[0].Size * (Files.Count - 1) : 0;
}
public record Result(List<Group> Groups, int Scanned, List<string> Errors, double Seconds, bool Cancelled, int CacheHits);
public record Progress(string Phase, int Done, int Total, string Path);
public sealed class Control : IDisposable {
    private readonly ManualResetEventSlim gate = new(true);
    private readonly CancellationTokenSource source = new();
    public CancellationToken Token => source.Token;
    public bool Cancelled => source.IsCancellationRequested;
    public void Pause() => gate.Reset();
    public void Resume() => gate.Set();
    public void Cancel() { source.Cancel(); gate.Set(); }
    public void Check() { source.Token.ThrowIfCancellationRequested(); gate.Wait(source.Token); }
    public void Dispose() { gate.Dispose(); source.Dispose(); }
}
public static class Identity {
    [StructLayout(LayoutKind.Sequential)] private struct Info {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    public static string Get(string path) {
        if (!OperatingSystem.IsWindows()) return System.IO.Path.GetFullPath(path);
        using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (!GetFileInformationByHandle(handle, out var i)) throw new IOException("无法取得文件身份");
        return $"{i.Volume}:{i.IndexHigh}:{i.IndexLow}";
    }
    public static bool Network(string path) {
        if (path.StartsWith(@"\\") && !path.StartsWith(@"\\?\")) return true;
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return true;
        return new DriveInfo(System.IO.Path.GetPathRoot(path)!).DriveType == DriveType.Network;
    }
}
public sealed class Scanner {
    public record Stamp(string Identity, long Size, long Write, long Created);
    public record CacheItem(Stamp Stamp, string Hash);
    private readonly ConcurrentDictionary<string,CacheItem> cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly string? cachePath;
    public Scanner(string? cachePath = null) {
        this.cachePath = cachePath;
        if (cachePath != null && File.Exists(cachePath)) {
            try {
                foreach (var pair in JsonSerializer.Deserialize<Dictionary<string,CacheItem>>(File.ReadAllText(cachePath)) ?? [])
                    cache[pair.Key] = pair.Value;
            } catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        }
    }
    public static bool Within(string path, string root) => path.Equals(root, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(root.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    public static Stamp Stat(string path) {
        var file = new FileInfo(path); file.Refresh();
        if (!file.Exists || file.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("文件不存在或是链接");
        return new(Identity.Get(path), file.Length, file.LastWriteTimeUtc.Ticks, file.CreationTimeUtc.Ticks);
    }
    public static string Hash(string path, Stamp expected, Control control, bool sample = false) {
        if (Stat(path) != expected) throw new IOException("文件在扫描后变化");
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[sample && expected.Size > 196608 ? 65536 : 1048576];
        if (sample && expected.Size > 196608) {
            foreach (var offset in new[] { 0L, expected.Size/2, expected.Size-65536 }) {
                control.Check(); stream.Position = offset; var size = stream.Read(buffer); hash.AppendData(buffer,0,size);
            }
        } else {
            while (true) { control.Check(); int size = stream.Read(buffer); if (size == 0) break; hash.AppendData(buffer,0,size); }
        }
        if (Stat(path) != expected) throw new IOException("读取期间文件变化");
        return Convert.ToHexString(hash.GetHashAndReset());
    }
    public async Task<Result> ScanAsync(IEnumerable<string> roots, Options options, Control control, IProgress<Progress>? progress = null) {
        var start = DateTime.UtcNow;
        var errors = new ConcurrentBag<string>();
        var files = new List<(Entry File,Stamp Stamp)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var dirs = new Dictionary<string,bool>(StringComparer.OrdinalIgnoreCase);
        int hits = 0;
        await Task.Run(() => {
            var stack = new Stack<(string Path,bool Recursive)>(roots.Select(System.IO.Path.GetFullPath).Select(p=>(p,options.Recursive&&!options.NonRecursiveRoots.Contains(p,StringComparer.OrdinalIgnoreCase))));
            try {
                while (stack.TryPop(out var current)) {
                    var directory=current.Path;
                    control.Check();
                    if (options.Excluded.Any(x=>Within(directory,x))) continue;
                    if (dirs.TryGetValue(directory,out var wasRecursive) && (wasRecursive || !current.Recursive)) continue;
                    dirs[directory]=current.Recursive;
                    try {
                        if (File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint)) continue;
                        foreach (var path in Directory.EnumerateFileSystemEntries(directory)) {
                            control.Check();
                            try {
                                var attributes = File.GetAttributes(path);
                                if (attributes.HasFlag(FileAttributes.ReparsePoint) ||
                                    (!options.Hidden && attributes.HasFlag(FileAttributes.Hidden)) ||
                                    options.Excluded.Any(x=>Within(path,x))) continue;
                                if (attributes.HasFlag(FileAttributes.Directory)) { if (current.Recursive) stack.Push((path,true)); continue; }
                                var file = new FileInfo(path);
                                if (file.Length < options.Minimum || file.Length > options.Maximum ||
                                    (options.Extensions.Length > 0 && !options.Extensions.Contains(file.Extension.TrimStart('.'),StringComparer.OrdinalIgnoreCase))) continue;
                                var stamp = Stat(path);
                                if (!seen.Add(stamp.Identity)) continue;
                                files.Add((new(path,file.Length,file.LastWriteTimeUtc,stamp.Identity,Identity.Network(path)),stamp));
                                if (files.Count % 100 == 0) progress?.Report(new("查找文件",files.Count,0,path));
                            } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { errors.Add(path+": "+e.Message); }
                        }
                    } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { errors.Add(directory+": "+e.Message); }
                }
            } catch (OperationCanceledException) { }
        });
        async Task<ConcurrentDictionary<string,ConcurrentBag<Entry>>> Compute(List<(Entry File,Stamp Stamp)> inputs, bool sample) {
            var output = new ConcurrentDictionary<string,ConcurrentBag<Entry>>();
            int done = 0;
            foreach (var network in new[]{false,true}) {
                await Parallel.ForEachAsync(inputs.Where(x=>x.File.Network==network),
                    new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(network?options.NetworkWorkers:options.LocalWorkers,1,8) },
                    async (item,_) => {
                        if (control.Cancelled) return;
                        for (int attempt=0;attempt<3;attempt++) {
                            try {
                                control.Check();
                                var key = item.File.Path + (sample?":sample":":full");
                                string hash;
                                if (cache.TryGetValue(key,out var entry) && entry.Stamp==item.Stamp) { hash=entry.Hash; Interlocked.Increment(ref hits); }
                                else { hash=Hash(item.File.Path,item.Stamp,control,sample); cache[key]=new(item.Stamp,hash); }
                                output.GetOrAdd(hash,_=>new()).Add(item.File);
                                break;
                            } catch (OperationCanceledException) { break; }
                            catch (Exception e) when (e is IOException or UnauthorizedAccessException) {
                                if (!network || attempt==2) { errors.Add(item.File.Path+": "+e.Message); break; }
                                await Task.Delay(250*(attempt+1));
                            }
                        }
                        var n=Interlocked.Increment(ref done);
                        if (n%20==0 || n==inputs.Count) progress?.Report(new(sample?"快速筛选":"校验内容",n,inputs.Count,item.File.Path));
                    });
            }
            return output;
        }
        var candidates=files.GroupBy(x=>x.File.Size).Where(g=>g.Count()>1).SelectMany(g=>g).ToList();
        var sampled=await Compute(candidates,true);
        var ids=sampled.Values.Where(x=>x.Count>1).SelectMany(x=>x).Select(x=>x.Identity).ToHashSet();
        var full=await Compute(candidates.Where(x=>ids.Contains(x.File.Identity)).ToList(),false);
        if(cachePath!=null) {
            try {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(cachePath)!);
                var temporary=cachePath+".tmp";
                await File.WriteAllTextAsync(temporary,JsonSerializer.Serialize(cache.Take(50000).ToDictionary()));
                File.Move(temporary,cachePath,true);
            } catch(Exception e) when(e is IOException or UnauthorizedAccessException) { errors.Add("缓存保存失败："+e.Message); }
        }
        return new(full.Where(x=>x.Value.Count>1).Select(x=>new Group(x.Key,x.Value.OrderBy(f=>f.Path).ToList()))
            .OrderByDescending(x=>x.Reclaimable).ToList(),files.Count,errors.ToList(),(DateTime.UtcNow-start).TotalSeconds,control.Cancelled,hits);
    }
    public static void Validate(Group group, HashSet<string> selected, string[] protectedPaths) {
        if (!selected.IsSubsetOf(group.Files.Select(f=>f.Path))) throw new IOException("选择不属于当前组");
        if (selected.Count==0) return;
        var keeper=group.Files.FirstOrDefault(f=>!selected.Contains(f.Path)) ?? throw new IOException("必须保留一份");
        using var control=new Control();
        var keepStamp=Stat(keeper.Path);
        if(Hash(keeper.Path,keepStamp,control)!=group.Hash) throw new IOException("保留文件发生变化");
        foreach(var path in selected) {
            if(Identity.Network(path) || protectedPaths.Any(x=>Within(path,x))) throw new IOException("网络卷或保护目录禁止清理");
            var stamp=Stat(path);
            if(stamp.Identity==keepStamp.Identity || Hash(path,stamp,control)!=group.Hash) throw new IOException("内容已变化或属于同一文件");
            using var a=File.OpenRead(path); using var b=File.OpenRead(keeper.Path);
            var x=new byte[1048576]; var y=new byte[1048576];
            while(true) { var n=a.Read(x); var m=b.Read(y); if(n!=m || !x.AsSpan(0,n).SequenceEqual(y.AsSpan(0,m))) throw new IOException("逐字节校验失败"); if(n==0) break; }
            if(Stat(path)!=stamp || Stat(keeper.Path)!=keepStamp) throw new IOException("校验期间文件变化");
        }
    }
}
