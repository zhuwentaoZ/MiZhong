using MiZhong.Core;
var root=Path.Combine(Path.GetTempPath(),"mizhong-tests-"+Guid.NewGuid());
Directory.CreateDirectory(root);
try {
    File.WriteAllText(Path.Combine(root,"a"),"duplicate");
    File.WriteAllText(Path.Combine(root,"b"),"duplicate");
    var scanner=new Scanner(); using var control=new Control();
    var r=await scanner.ScanAsync([root,root],new Options(),control);
    if(r.Scanned!=2 || r.Groups.Count!=1) throw new Exception("duplicates/overlap failed");
    var filtered=await scanner.ScanAsync([root],new Options{Minimum=100},control);
    if(filtered.Scanned!=0) throw new Exception("size filter failed");
    using var cancelled=new Control(); cancelled.Cancel();
    var partial=await scanner.ScanAsync([root],new Options(),cancelled);
    if(!partial.Cancelled || partial.Scanned!=0) throw new Exception("cancel failed");
    File.WriteAllText(Path.Combine(root,"b"),"different");
    var changed=await scanner.ScanAsync([root],new Options(),control);
    if(changed.Groups.Count!=0) throw new Exception("cache invalidation failed");
    Console.WriteLine("PASS: duplicates, overlapping roots, size filter, cancellation, cache invalidation");
} finally { Directory.Delete(root,true); }
