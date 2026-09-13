using MiZhong.Core;
using System.IO;
using Control = MiZhong.Core.Control;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Microsoft.VisualBasic.FileIO;

namespace MiZhong;
static class Program {
    [STAThread] static void Main(string[] args) {
        if(args.Length==2&&args[0]=="--self-test") { WindowsSelfTest.Run(args[1]); return; }
        ApplicationConfiguration.Initialize(); Application.Run(new MainForm());
    }
}
sealed class MainForm : Form {
    readonly ListBox roots=new(){Height=110,Dock=DockStyle.Top};
    readonly CheckBox recursive=new(){Text="搜索子目录",Checked=true,AutoSize=true}, hidden=new(){Text="包含隐藏文件",AutoSize=true},
        images=new(){Text="查找相似图片（默认关闭）",AutoSize=true}, useCache=new(){Text="本地增量缓存",Checked=true,AutoSize=true};
    readonly NumericUpDown minimum=new(){Maximum=1000000000,Width=95}, maximum=new(){Maximum=1000000000,Width=95},
        workers=new(){Minimum=1,Maximum=8,Value=4,Width=65}, networkWorkers=new(){Minimum=1,Maximum=4,Value=2,Width=65};
    readonly ComboBox threshold=new(){DropDownStyle=ComboBoxStyle.DropDownList,Width=140};
    readonly TextBox extensions=new(){PlaceholderText="扩展名：jpg,png,pdf；留空不限",Width=280},
        excluded=new(){Multiline=true,Height=65,Width=280,PlaceholderText="排除目录，每行一个"},
        protectedPaths=new(){Multiline=true,Height=65,Width=280,PlaceholderText="保护目录，每行一个"},
        search=new(){PlaceholderText="筛选文件名或路径",Width=280};
    readonly Label status=new(){Text="添加本地文件夹或已挂载的 UNC 共享以开始",AutoSize=true,MaximumSize=new(850,0)};
    readonly Button start=new(){Text="开始扫描",AutoSize=true},pause=new(){Text="暂停",Enabled=false,AutoSize=true},
        cancel=new(){Text="取消",Enabled=false,AutoSize=true},trash=new(){Text="移至回收站",Enabled=false,AutoSize=true};
    readonly ListView exact=new(){Dock=DockStyle.Fill,View=View.Details,CheckBoxes=true,FullRowSelect=true};
    readonly ListView similar=new(){Dock=DockStyle.Fill,View=View.Details,FullRowSelect=true};
    readonly TabControl tabs=new(){Dock=DockStyle.Fill};
    Control? control;
    Result? result;
    bool paused, busy;
    string? preferred;
    readonly HashSet<string> shallow=new(StringComparer.OrdinalIgnoreCase);
    readonly string support=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"MiZhong");
    readonly List<ImagePair> pairs=[];
    sealed record Preferences(bool Recursive,bool Hidden,decimal Minimum,decimal Maximum,string Extensions,string Excluded,string Protected,bool Cache,string? Preferred=null,string[]? Roots=null,string[]? Shallow=null);
    public MainForm() {
        Text="觅重 · 0.3"; Width=1240; Height=820; MinimumSize=new(1000,680); Font=new Font("Microsoft YaHei UI",10);
        BackColor=Color.FromArgb(245,247,251);
        var sidebar=new FlowLayoutPanel{Dock=DockStyle.Left,Width=325,Padding=new(20),FlowDirection=FlowDirection.TopDown,WrapContents=false,AutoScroll=true};
        var brand=new Label{Text="觅重",Font=new Font(Font.FontFamily,25,FontStyle.Bold),AutoSize=true,ForeColor=Color.RoyalBlue};
        sidebar.Controls.Add(brand);
        sidebar.Controls.Add(new Label{Text="本地分析 · NAS 只读 · 不保存凭据",AutoSize=true});
        roots.Width=280;sidebar.Controls.Add(roots);
        var rootMenu=new ContextMenuStrip();var topOnly=new ToolStripMenuItem("仅扫描此位置顶层");rootMenu.Items.Add(topOnly);
        rootMenu.Opening+=(_,e)=>{if(busy||roots.SelectedItem is not string p){e.Cancel=true;return;}topOnly.Checked=shallow.Contains(p);};
        topOnly.Click+=(_,_)=>{if(roots.SelectedItem is string p){if(!shallow.Add(p))shallow.Remove(p);}};roots.ContextMenuStrip=rootMenu;
        var add=new Button{Text="添加文件夹 / NAS…",AutoSize=true};
        add.Click+=(_,_)=>{using var d=new FolderBrowserDialog{UseDescriptionForTitle=true,Description="选择本地目录或 UNC 共享"};if(d.ShowDialog()==DialogResult.OK&&!roots.Items.Contains(d.SelectedPath))roots.Items.Add(d.SelectedPath);};
        sidebar.Controls.Add(add);
        var remove=new Button{Text="移除所选位置",AutoSize=true};remove.Click+=(_,_)=>{if(roots.SelectedItem!=null)roots.Items.Remove(roots.SelectedItem);};sidebar.Controls.Add(remove);
        sidebar.Controls.Add(recursive);sidebar.Controls.Add(hidden);sidebar.Controls.Add(images);
        threshold.Items.AddRange(["严格","标准","宽松"]);threshold.SelectedIndex=1;sidebar.Controls.Add(threshold);
        sidebar.Controls.Add(new Label{Text="大小 MiB（最大值 0 表示不限）",AutoSize=true});
        var range=new FlowLayoutPanel{Width=280,Height=35};range.Controls.AddRange([new Label{Text="最小",AutoSize=true},minimum,new Label{Text="最大",AutoSize=true},maximum]);sidebar.Controls.Add(range);
        sidebar.Controls.Add(extensions);sidebar.Controls.Add(excluded);sidebar.Controls.Add(protectedPaths);sidebar.Controls.Add(useCache);
        var preferredButton=new Button{Text="优先保留目录…",AutoSize=true};preferredButton.Click+=(_,_)=>{using var d=new FolderBrowserDialog();if(d.ShowDialog()==DialogResult.OK){preferred=d.SelectedPath;preferredButton.Text="优先保留："+Path.GetFileName(preferred);}};sidebar.Controls.Add(preferredButton);
        var pool=new FlowLayoutPanel{Width=280,Height=36};pool.Controls.AddRange([new Label{Text="本地并发",AutoSize=true},workers,new Label{Text="NAS",AutoSize=true},networkWorkers]);sidebar.Controls.Add(pool);
        var run=new FlowLayoutPanel{Width=280,Height=42};run.Controls.AddRange([start,pause,cancel]);sidebar.Controls.Add(run);
        var cacheClear=new Button{Text="清空缓存",AutoSize=true};cacheClear.Click+=(_,_)=>{if(!busy){Directory.CreateDirectory(support);File.WriteAllText(Path.Combine(support,"cache.json"),"{}");}};sidebar.Controls.Add(cacheClear);
        start.Click+=async(_,_)=>await Scan();
        pause.Click+=(_,_)=>{paused=!paused;if(paused)control?.Pause();else control?.Resume();pause.Text=paused?"继续":"暂停";};
        cancel.Click+=(_,_)=>{control?.Cancel();status.Text="正在取消，等待当前读取返回…";};
        var area=new Panel{Dock=DockStyle.Fill,Padding=new(20)};
        var tools=new FlowLayoutPanel{Dock=DockStyle.Top,Height=86};
        var select=new Button{Text="建议保留一份",AutoSize=true};select.Click+=(_,_)=>SelectCopies();
        var clear=new Button{Text="清空选择",AutoSize=true};clear.Click+=(_,_)=>{foreach(ListViewItem row in exact.Items)row.Checked=false;};
        var export=new Button{Text="导出 JSON",AutoSize=true};export.Click+=(_,_)=>Export(true);
        var csv=new Button{Text="导出 CSV",AutoSize=true};csv.Click+=(_,_)=>Export(false);
        var errors=new Button{Text="查看错误",AutoSize=true};errors.Click+=(_,_)=>MessageBox.Show(string.Join(Environment.NewLine,result?.Errors??[]),"读取错误");
        trash.Click+=async(_,_)=>await Trash();
        tools.Controls.AddRange([search,select,clear,export,csv,errors,trash]);
        search.TextChanged+=(_,_)=>Render();
        foreach(var (title,width) in new[]{("重复组",90),("文件",200),("大小",100),("路径",480),("修改时间",180),("位置",90)}) exact.Columns.Add(title,width);
        foreach(var (title,width) in new[]{("指纹接近度",120),("图片 A",340),("图片 B",340)}) similar.Columns.Add(title,width);
        exact.DoubleClick+=(_,_)=>{if(exact.SelectedItems.Count>0&&exact.SelectedItems[0].Tag is Entry e)ShowFile(e.Path);};
        exact.ItemCheck+=(_,e)=>{
            if(e.NewValue!=CheckState.Checked||exact.Items[e.Index].Tag is not Entry item)return;
            if(item.Network||Protected().Any(p=>Scanner.Within(item.Path,p))||result?.Cancelled==true){e.NewValue=CheckState.Unchecked;return;}
            var group=result?.Groups.FirstOrDefault(g=>g.Files.Contains(item));
            if(group!=null&&exact.CheckedItems.Cast<ListViewItem>().Count(x=>x.Tag is Entry a&&group.Files.Contains(a))>=group.Files.Count-1)e.NewValue=CheckState.Unchecked;
        };
        similar.DoubleClick+=(_,_)=>{if(similar.SelectedItems.Count>0&&similar.SelectedItems[0].Tag is ImagePair p)new CompareForm(p).ShowDialog(this);};
        var a=new TabPage("完全重复");a.Controls.Add(exact);var b=new TabPage("相似图片 · 双击比较");b.Controls.Add(similar);tabs.TabPages.AddRange([a,b]);
        var footer=new Panel{Dock=DockStyle.Bottom,Height=65};footer.Controls.Add(status);
        area.Controls.Add(tabs);area.Controls.Add(tools);area.Controls.Add(footer);Controls.Add(area);Controls.Add(sidebar);
        LoadPreferences();FormClosing+=(_,_)=>control?.Cancel();
    }
    string[] Protected()=>protectedPaths.Lines.Where(x=>!string.IsNullOrWhiteSpace(x)).ToArray();
    void LoadPreferences(){
        try{var path=Path.Combine(support,"settings.json");if(!File.Exists(path))return;var s=JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path));if(s==null)return;
            recursive.Checked=s.Recursive;hidden.Checked=s.Hidden;minimum.Value=Math.Clamp(s.Minimum,minimum.Minimum,minimum.Maximum);maximum.Value=Math.Clamp(s.Maximum,maximum.Minimum,maximum.Maximum);
            extensions.Text=s.Extensions;excluded.Text=s.Excluded;protectedPaths.Text=s.Protected;useCache.Checked=s.Cache;
            preferred=s.Preferred;foreach(var p in s.Roots??[])roots.Items.Add(p);shallow.UnionWith(s.Shallow??[]);
        }catch(IOException){}catch(JsonException){}
    }
    async Task Scan(){
        if(busy)return;if(roots.Items.Count==0){MessageBox.Show("请先添加扫描位置");return;}
        if(maximum.Value>0&&maximum.Value<minimum.Value){MessageBox.Show("最大值不能小于最小值");return;}
        busy=true;start.Enabled=false;pause.Enabled=cancel.Enabled=true;trash.Enabled=false;result=null;pairs.Clear();Render();
        control?.Dispose();control=new();paused=false;
        var options=new Options{Recursive=recursive.Checked,Hidden=hidden.Checked,Minimum=Math.Max(1,(long)minimum.Value*1048576),
            Maximum=maximum.Value==0?long.MaxValue:(long)maximum.Value*1048576,Extensions=extensions.Text.Split([',','，',' '],StringSplitOptions.RemoveEmptyEntries).Select(x=>x.TrimStart('.')).ToArray(),
            Excluded=excluded.Lines.Where(x=>!string.IsNullOrWhiteSpace(x)).ToArray(),LocalWorkers=(int)workers.Value,NetworkWorkers=(int)networkWorkers.Value,NonRecursiveRoots=shallow.ToArray()};
        var paths=roots.Items.Cast<string>().ToArray();var analyze=images.Checked;var distance=new[]{4,8,12}[threshold.SelectedIndex];
        try{
            Directory.CreateDirectory(support);
            File.WriteAllText(Path.Combine(support,"settings.json"),JsonSerializer.Serialize(new Preferences(recursive.Checked,hidden.Checked,minimum.Value,maximum.Value,extensions.Text,excluded.Text,protectedPaths.Text,useCache.Checked,preferred,paths,shallow.ToArray())));
            result=await new Scanner(useCache.Checked?Path.Combine(support,"cache.json"):null).ScanAsync(paths,options,control,
                new System.Progress<MiZhong.Core.Progress>(p=>status.Text=$"{p.Phase} · {p.Done}/{p.Total}\n{p.Path}"));
            if(analyze&&!control.Cancelled){
                status.Text="正在分析相似图片…";
                pairs.AddRange(await Task.Run(()=>ImageAnalysis.Find(paths,options,distance,control,result.Errors)));
            }
            status.Text=$"{(control.Cancelled?"已取消 · 部分结果":"扫描完成")} · {result.Scanned:N0} 个文件 · {result.Groups.Count} 组重复 · 缓存 {result.CacheHits} · {result.Seconds:F2} 秒\n网络卷只读；相似图片分数不是准确率。";
        }catch(OperationCanceledException){status.Text="扫描已取消";}catch(Exception e){MessageBox.Show(e.Message,"扫描失败");}
        finally{if(result!=null&&control.Cancelled)result=result with{Cancelled=true};busy=false;start.Enabled=true;pause.Enabled=cancel.Enabled=false;pause.Text="暂停";trash.Enabled=result?.Cancelled==false;Render();}
    }
    void Render(){
        exact.BeginUpdate();exact.Items.Clear();similar.Items.Clear();
        if(result!=null)for(int i=0;i<result.Groups.Count;i++)foreach(var f in result.Groups[i].Files){
            if(!f.Path.Contains(search.Text,StringComparison.OrdinalIgnoreCase))continue;
            var row=new ListViewItem([(i+1).ToString(),Path.GetFileName(f.Path),$"{f.Size/1048576.0:F2} MiB",f.Path,f.Modified.ToLocalTime().ToString(),f.Network?"NAS · 只读":"本地"]){Tag=f};exact.Items.Add(row);
        }
        foreach(var p in pairs.Where(p=>p.A.Contains(search.Text,StringComparison.OrdinalIgnoreCase)||p.B.Contains(search.Text,StringComparison.OrdinalIgnoreCase)))similar.Items.Add(new ListViewItem([$"{100*(1-p.Distance/64.0):F0}%",p.A,p.B]){Tag=p});
        exact.EndUpdate();
    }
    void SelectCopies(){
        if(result==null||busy||result.Cancelled)return;
        foreach(var g in result.Groups){
            var keep=g.Files.OrderBy(f=>f.Network||Protected().Any(p=>Scanner.Within(f.Path,p))?0:preferred!=null&&Scanner.Within(f.Path,preferred)?1:2).ThenBy(f=>f.Path.Length).First();
            foreach(ListViewItem row in exact.Items)if(row.Tag is Entry f&&g.Files.Contains(f))row.Checked=f!=keep&&!f.Network&&!Protected().Any(p=>Scanner.Within(f.Path,p));
        }
    }
    void Export(bool json){
        if(result==null||busy)return;using var dialog=new SaveFileDialog{FileName=json?"觅重报告.json":"觅重报告.csv",Filter=json?"JSON|*.json":"CSV|*.csv"};
        if(dialog.ShowDialog()!=DialogResult.OK)return;
        try{if(json)File.WriteAllText(dialog.FileName,JsonSerializer.Serialize(new{Scan=result,SimilarImages=pairs},new JsonSerializerOptions{WriteIndented=true}));
            else{
                static string Q(string s)=>"\""+s.Replace("\"","\"\"")+"\"";
                var rows=new List<string>{"hash,path,size_bytes,modified_utc,network"};
                rows.AddRange(result.Groups.SelectMany(g=>g.Files.Select(f=>$"{g.Hash},{Q(f.Path)},{f.Size},{f.Modified:O},{f.Network}")));
                File.WriteAllLines(dialog.FileName,rows,System.Text.Encoding.UTF8);
            }
        }catch(Exception e){MessageBox.Show(e.Message);}
    }
    async Task Trash(){
        if(busy||result==null||result.Cancelled)return;
        var selected=exact.CheckedItems.Cast<ListViewItem>().Select(x=>(Entry)x.Tag!).Select(x=>x.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        if(selected.Count==0)return;
        if(MessageBox.Show($"将 {selected.Count} 个本地文件移至回收站？\n"+string.Join("\n",selected),"确认清理",MessageBoxButtons.OKCancel,MessageBoxIcon.Warning)!=DialogResult.OK)return;
        var original=result;var protection=Protected();busy=true;start.Enabled=trash.Enabled=false;
        var logs=await Task.Run(()=>{
            var lines=new List<string>();
            try{
                foreach(var group in original.Groups)Scanner.Validate(group,selected.Intersect(group.Files.Select(x=>x.Path)).ToHashSet(),protection);
                foreach(var group in original.Groups){
                    var targets=group.Files.Where(x=>selected.Contains(x.Path)).ToArray();
                    foreach(var target in targets){
                        try{
                            var current=new Group(group.Hash,group.Files.Where(x=>x==target||!selected.Contains(x.Path)).ToList());
                            Scanner.Validate(current,[target.Path],protection);
                            FileSystem.DeleteFile(target.Path,UIOption.OnlyErrorDialogs,RecycleOption.SendToRecycleBin,UICancelOption.ThrowException);
                            lines.Add(target.Path+"：已移至回收站");
                        }catch(Exception e){lines.Add(target.Path+"："+e.Message);}
                    }
                }
            }catch(Exception e){lines.Add("校验未通过，未执行清理："+e.Message);}
            return lines;
        });
        try{File.WriteAllText(Path.Combine(support,$"cleanup-{Guid.NewGuid()}.json"),JsonSerializer.Serialize(logs));}catch(Exception e){logs.Add("日志保存失败："+e.Message);}
        busy=false;start.Enabled=true;result=null;Render();MessageBox.Show(string.Join("\n",logs),"操作结果");
    }
    static void ShowFile(string path)=>Process.Start(new ProcessStartInfo("explorer.exe",$"/select,\"{path}\""){UseShellExecute=true});
}
