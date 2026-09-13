using System.IO;
using System.Runtime.InteropServices;
using System.Drawing.Imaging;
using MiZhong.Core;
using Control = MiZhong.Core.Control;

namespace MiZhong;
static class WindowsSelfTest {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateHardLink(string link,string existing,IntPtr unused);
    public static void Run(string report) {
        var root=Path.Combine(Path.GetTempPath(),"mizhong-native-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try {
            string a=Path.Combine(root,"a.txt"),b=Path.Combine(root,"b.txt");File.WriteAllText(a,"duplicate");File.WriteAllText(b,"duplicate");
            if(!CreateHardLink(Path.Combine(root,"hard.txt"),a,IntPtr.Zero))throw new Exception("Hardlink fixture failed");
            using var control=new Control();
            var r=new Scanner().ScanAsync([root],new Options(),control).GetAwaiter().GetResult();
            if(r.Scanned!=2||r.Groups.Count!=1)throw new Exception("Native file identity failed");
            Scanner.Validate(r.Groups[0],[b],[]);
            using(var bitmap=new Bitmap(64,64)){
                for(int y=0;y<64;y++)for(int x=0;x<64;x++)bitmap.SetPixel(x,y,Color.FromArgb(x*4,y*4,(x+y)*2));
                bitmap.Save(Path.Combine(root,"image.png"),ImageFormat.Png);bitmap.Save(Path.Combine(root,"image.jpg"),ImageFormat.Jpeg);
            }
            var errors=new List<string>();var pairs=ImageAnalysis.Find([root],new Options(),8,control,errors);
            if(pairs.Count!=1||errors.Count!=0)throw new Exception("Native image analysis failed");
            File.WriteAllText(report,"PASS: Windows hardlink identity, cleanup preflight, PNG/JPEG similarity");
        } finally { Directory.Delete(root,true); }
    }
}
