// bpdump: like `di2x json`, but with CUE4Parse's ReadScriptData on, so Blueprint functions carry their Kismet
// bytecode (ScriptBytecode). Local-only, reads the user's own DI2 paks; output under extracted\json_bp.
//   bpdump <regex> [max]
using System.Text.RegularExpressions;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;
using Serilog;

const string Paks = @"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Content\Paks";
const string Root = @".";
Log.Logger = new LoggerConfiguration().MinimumLevel.Warning().WriteTo.Console().CreateLogger();
if (args.Length == 0) { Console.WriteLine("usage: bpdump <regex> [max]"); return 1; }
var toolDir = AppContext.BaseDirectory;
var oodlePath = Path.Combine(toolDir, OodleHelper.OodleFileName);
if (!File.Exists(oodlePath)) oodlePath = Path.Combine(Root, "tools", "di2x", "bin", "out", OodleHelper.OodleFileName);
OodleHelper.Initialize(oodlePath);
var zlib = Path.Combine(toolDir, ZlibHelper.DllName);
if (!File.Exists(zlib)) zlib = Path.Combine(Root, "tools", "di2x", "bin", "out", ZlibHelper.DllName);
ZlibHelper.Initialize(zlib);
var provider = new DefaultFileProvider(Paks, SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_DeadIsland2));
provider.ReadScriptData = true;
provider.Initialize();
var key = File.ReadAllText(Path.Combine(Root, "recon", "aes_key.txt")).Trim();
provider.SubmitKey(new FGuid(), new FAesKey(key));
provider.PostMount();
var rx = new Regex(args[0], RegexOptions.IgnoreCase);
var max = args.Length > 1 ? int.Parse(args[1]) : int.MaxValue;
foreach (var path in provider.Files.Keys.Where(k => rx.IsMatch(k) && k.EndsWith(".uasset")).OrderBy(k => k).Take(max))
{
    try
    {
        var exports = provider.LoadPackage(path).GetExports();
        var dest = Path.Combine(Root, "extracted", "json_bp", Path.ChangeExtension(path, ".json"));
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        File.WriteAllText(dest, JsonConvert.SerializeObject(exports, Formatting.Indented));
        Console.WriteLine($"ok   {path}");
    }
    catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
}
return 0;
