using MiZhong.Core;
using System.IO;
using Control = MiZhong.Core.Control;
using System.Numerics;
using System.Drawing.Drawing2D;

namespace MiZhong;
record ImagePair(string A,string B,int Distance);
static class ImageAnalysis {
    static readonly HashSet<string> Formats=new([".jpg",".jpeg",".png",".bmp",".gif",".tif",".tiff",".webp",".heic",".heif"],StringComparer.OrdinalIgnoreCase);
    internal static Image Load(string path) {
        try { return Image.FromFile(path); }
        catch (Exception e) when (e is ArgumentException or OutOfMemoryException) {
            using var stream=File.OpenRead(path);
            var decoder=System.Windows.Media.Imaging.BitmapDecoder.Create(stream,System.Windows.Media.Imaging.BitmapCreateOptions.PreservePixelFormat,System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
            var encoder=new System.Windows.Media.Imaging.BmpBitmapEncoder();encoder.Frames.Add(decoder.Frames[0]);
            using var memory=new MemoryStream();encoder.Save(memory);memory.Position=0;
            using var decoded=Image.FromStream(memory);return new Bitmap(decoded);
        }
    }
    sealed record Print(ulong[] Hashes,double Mean,double Deviation);
    static Print Hash(string path){
        using var image=Load(path);
        if(image.PropertyIdList.Contains(0x112)){
            var orientation=BitConverter.ToUInt16(image.GetPropertyItem(0x112)!.Value!,0);
            image.RotateFlip(orientation switch{3=>RotateFlipType.Rotate180FlipNone,6=>RotateFlipType.Rotate90FlipNone,8=>RotateFlipType.Rotate270FlipNone,_=>RotateFlipType.RotateNoneFlipNone});
        }
        var hashes=new List<ulong>();double mean=0,dev=0;
        foreach(var scale in new[]{1.0,.9,.8}){
            using var thumb=new Bitmap(9,8);using(var g=Graphics.FromImage(thumb)){
                g.InterpolationMode=InterpolationMode.HighQualityBicubic;
                g.DrawImage(image,new Rectangle(0,0,9,8),new RectangleF((float)(image.Width*(1-scale)/2),(float)(image.Height*(1-scale)/2),(float)(image.Width*scale),(float)(image.Height*scale)),GraphicsUnit.Pixel);
            }
            var values=new double[72];for(int y=0;y<8;y++)for(int x=0;x<9;x++){var c=thumb.GetPixel(x,y);values[y*9+x]=.299*c.R+.587*c.G+.114*c.B;}
            if(hashes.Count==0){mean=values.Average();dev=Math.Sqrt(values.Average(x=>Math.Pow(x-mean,2)));}
            ulong hash=0;for(int y=0;y<8;y++)for(int x=0;x<8;x++){hash<<=1;if(values[y*9+x]>values[y*9+x+1])hash|=1;}
            hashes.Add(hash);
        }
        return new(hashes.ToArray(),mean,dev);
    }
    static int Distance(Print a,Print b)=>Math.Min(a.Deviation,b.Deviation)<3&&Math.Abs(a.Mean-b.Mean)>8?64:a.Hashes.SelectMany(x=>b.Hashes.Select(y=>BitOperations.PopCount(x^y))).Min();
    public static List<ImagePair> Find(string[] roots,Options options,int threshold,Control control,List<string> errors){
        var result=new List<ImagePair>();var representatives=new List<(string Path,Print Print)>();
        var buckets=new Dictionary<ulong,HashSet<int>>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var stack=new Stack<(string Path,bool Recursive)>(roots.Select(p=>(p,options.Recursive&&!options.NonRecursiveRoots.Contains(p,StringComparer.OrdinalIgnoreCase))));
        var dirs=new Dictionary<string,bool>(StringComparer.OrdinalIgnoreCase);
        while(stack.TryPop(out var current)){
            var dir=current.Path;control.Check();if(options.Excluded.Any(x=>Scanner.Within(dir,x)))continue;
            if(dirs.TryGetValue(dir,out var old)&&(old||!current.Recursive))continue;dirs[dir]=current.Recursive;
            try{
                if(File.GetAttributes(dir).HasFlag(FileAttributes.ReparsePoint))continue;
                foreach(var path in Directory.EnumerateFileSystemEntries(dir)){
                    control.Check();
                    var attrs=File.GetAttributes(path);
                    if(attrs.HasFlag(FileAttributes.ReparsePoint)||(!options.Hidden&&attrs.HasFlag(FileAttributes.Hidden))||options.Excluded.Any(x=>Scanner.Within(path,x)))continue;
                    if(attrs.HasFlag(FileAttributes.Directory)){if(current.Recursive)stack.Push((path,true));continue;}
                    if(!Formats.Contains(Path.GetExtension(path)))continue;
                    var info=new FileInfo(path);
                    if(info.Length<options.Minimum||info.Length>options.Maximum||(options.Extensions.Length>0&&!options.Extensions.Contains(info.Extension.TrimStart('.'),StringComparer.OrdinalIgnoreCase)))continue;
                    try{
                        if(!seen.Add(Identity.Get(path)))continue;
                        var print=Hash(path);var candidates=new HashSet<int>();var keys=new HashSet<ulong>();
                        foreach(var hash in print.Hashes)for(int part=0;part<=threshold;part++){
                            int shift=part*64/(threshold+1),end=(part+1)*64/(threshold+1);
                            ulong key=((ulong)part<<60)|((hash>>shift)&((1UL<<(end-shift))-1));
                            keys.Add(key);if(buckets.TryGetValue(key,out var values))candidates.UnionWith(values);
                        }
                        var match=candidates.Order().FirstOrDefault(i=>Distance(print,representatives[i].Print)<=threshold,-1);
                        if(match>=0)result.Add(new(representatives[match].Path,path,Distance(print,representatives[match].Print)));
                        else{int id=representatives.Count;representatives.Add((path,print));foreach(var key in keys){if(!buckets.ContainsKey(key))buckets[key]=[];buckets[key].Add(id);}}
                    }catch(Exception e)when(e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or System.Runtime.InteropServices.COMException){errors.Add(path+"：图片分析失败 "+e.Message);}
                }
            }catch(Exception e)when(e is IOException or UnauthorizedAccessException){errors.Add(dir+"："+e.Message);}
        }
        return result;
    }
}
sealed class CompareForm:Form {
    public CompareForm(ImagePair pair){
        Text="觅重 · 图片对比";Width=1040;Height=720;Font=new Font("Microsoft YaHei UI",10);
        var layout=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=2};
        layout.ColumnStyles.Add(new(SizeType.Percent,50));layout.ColumnStyles.Add(new(SizeType.Percent,50));layout.RowStyles.Add(new(SizeType.Percent,90));layout.RowStyles.Add(new(SizeType.Percent,10));
        int i=0;foreach(var path in new[]{pair.A,pair.B}){
            var picture=new PictureBox{Dock=DockStyle.Fill,SizeMode=PictureBoxSizeMode.Zoom};
            using(var source=ImageAnalysis.Load(path)){picture.Image=new Bitmap(source);}
            picture.Disposed+=(_,_)=>picture.Image?.Dispose();layout.Controls.Add(picture,i,0);
            layout.Controls.Add(new TextBox{Text=path,ReadOnly=true,Multiline=true,Dock=DockStyle.Fill},i++,1);
        }
        Controls.Add(layout);
    }
}
