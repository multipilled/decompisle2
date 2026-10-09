// di2x: local-only extractor for the user's own Dead Island 2 install (personal testing).
// Reads the retail paks with CUE4Parse; output goes under extracted (never shared).
//
//   di2x list  [regex]                 -> extracted/files.txt (all package paths, or those matching regex)
//   di2x json  <regex> [max]           -> extracted/json/<path>.json (property dumps)
//   di2x mesh  <regex> [max]           -> extracted/mesh/<path>.gltf (+ textures as png)
//   di2x tex   <regex> [max]           -> extracted/tex/<path>.png
//   di2x anim  <regex> [max]           -> extracted/anim/<path>.gltf
using System.Text.RegularExpressions;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Assets.Exports.Animation;
using CUE4Parse.UE4.Assets.Exports.SkeletalMesh;
using CUE4Parse.UE4.Assets.Exports.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using Newtonsoft.Json;
using Serilog;

const string Paks = @"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Content\Paks";
const string Root = @".";
var outRoot = Path.Combine(Root, "extracted");

Log.Logger = new LoggerConfiguration().MinimumLevel.Warning().WriteTo.Console().CreateLogger();

if (args.Length == 0)
{
    Console.WriteLine("usage: di2x list|json|mesh|tex|anim <regex> [max]");
    return 1;
}

var toolDir = AppContext.BaseDirectory;
var oodlePath = Path.Combine(toolDir, OodleHelper.OodleFileName);
if (!File.Exists(oodlePath)) OodleHelper.DownloadOodleDll(ref oodlePath);
OodleHelper.Initialize(oodlePath);
ZlibHelper.Initialize(Path.Combine(toolDir, ZlibHelper.DllName));
// Detex decodes the block formats CUE4Parse's managed decoders don't (e.g. the hair data maps); its DLL
// is embedded in CUE4Parse-Conversion and extracted next to the tool on first use.
var detexPath = Path.Combine(toolDir, CUE4Parse_Conversion.Textures.BC.DetexHelper.DLL_NAME);
if (CUE4Parse_Conversion.Textures.BC.DetexHelper.LoadDll(detexPath))
    CUE4Parse_Conversion.Textures.BC.DetexHelper.Initialize(detexPath);

var version = new VersionContainer(EGame.GAME_DeadIsland2);
var provider = new DefaultFileProvider(Paks, SearchOption.TopDirectoryOnly, version);
var usmap = Directory.Exists(Path.Combine(Root, "recon"))
    ? Directory.GetFiles(Path.Combine(Root, "recon"), "*.usmap").FirstOrDefault()
    : null;
if (usmap != null) provider.MappingsContainer = new FileUsmapTypeMappingsProvider(usmap);
provider.Initialize();
var key = File.ReadAllText(Path.Combine(Root, "recon", "aes_key.txt")).Trim();
var mounted = provider.SubmitKey(new FGuid(), new FAesKey(key));
provider.PostMount();
Console.Error.WriteLine($"mounted {mounted} containers, {provider.Files.Count} files, mappings: {(usmap ?? "none")}");

var cmd = args[0];
var rx = new Regex(args.Length > 1 && !args[1].StartsWith("@") ? args[1] : ".", RegexOptions.IgnoreCase);
var max = args.Length > 2 ? int.Parse(args[2]) : int.MaxValue;
// "@file" = exact asset names (one per line) instead of a regex.
HashSet<string>? nameSet = args.Length > 1 && args[1].StartsWith("@")
    ? new HashSet<string>(File.ReadAllLines(args[1][1..]).Select(l => l.Trim()).Where(l => l.Length > 0), StringComparer.OrdinalIgnoreCase)
    : null;
var matches = provider.Files.Keys
    .Where(k => nameSet != null ? nameSet.Contains(Path.GetFileNameWithoutExtension(k)) && k.EndsWith(".uasset") : rx.IsMatch(k))
    .OrderBy(k => k).ToList();

var options = new ExportOptions(meshFormat: cmd == "anim" ? EMeshFormat.ActorX : EMeshFormat.Gltf2, textureFormat: ETextureFormat.Png,
    exportHdrTexturesAsHdr: false, exportMaterials: true, exportMorphTargets: Environment.GetEnvironmentVariable("DI2X_MORPHS") == "1");

switch (cmd)
{
    case "list":
    {
        Directory.CreateDirectory(outRoot);
        var listPath = Path.Combine(outRoot, args.Length > 1 ? "files_filtered.txt" : "files.txt");
        File.WriteAllLines(listPath, matches);
        Console.WriteLine($"{matches.Count} paths -> {listPath}");
        break;
    }
    case "json":
    {
        foreach (var path in matches.Where(p => p.EndsWith(".uasset") || p.EndsWith(".umap")).Take(max))
        {
            try
            {
                var exports = provider.LoadPackage(path).GetExports();
                var dest = Path.Combine(outRoot, "json", Path.ChangeExtension(path, ".json"));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.WriteAllText(dest, JsonConvert.SerializeObject(exports, Formatting.Indented));
                Console.WriteLine($"ok   {path}");
            }
            catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
        }
        break;
    }
    case "mesh":
    case "tex":
    case "anim":
    {
        var session = new ExportSession();
        var queued = 0;
        foreach (var path in matches.Where(p => p.EndsWith(".uasset")).Take(max))
        {
            try
            {
                foreach (var obj in provider.LoadPackage(path).GetExports())
                {
                    var want = cmd switch
                    {
                        "mesh" => obj is USkeletalMesh or UStaticMesh,
                        "anim" => obj is UAnimSequence or UAnimMontage,
                        _ => obj is UTexture2D,
                    };
                    if (!want) continue;
                    session.Add(obj);
                    queued++;
                }
            }
            catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
        }
        Console.WriteLine($"queued {queued} {cmd} exports");
        var results = await session.RunAsync(Path.Combine(outRoot, cmd), options);
        foreach (var r in results) Console.WriteLine(r);
        break;
    }
    case "rawanim":
    {
        // Raw ACL streams + metadata, for decoding with the matching (older) ACL release in tools/acl1x.
        Console.WriteLine($"rawanim: {matches.Count} matches");
        var dir = Path.Combine(outRoot, "rawanim");
        Directory.CreateDirectory(dir);
        foreach (var path in matches.Where(p => p.EndsWith(".uasset")).Take(max))
        {
            try
            {
                var exports = provider.LoadPackage(path).GetExports().ToList();
                if (!exports.OfType<UAnimSequence>().Any())
                    Console.WriteLine($"skip {path}: exports {string.Join(",", exports.Select(e => e.GetType().Name))}");
                foreach (var seq in exports.OfType<UAnimSequence>())
                {
                    var skel = seq.Skeleton.Load<USkeleton>()!;
                    var refSkel = skel.ReferenceSkeleton;
                    var codec = seq.CompressedDataStructure;
                    // Pose the clip was authored on (UE retarget source); null = the skeleton's ref pose.
                    var source = seq.RetargetSource.IsNone ? null : seq.RetargetSource.Text;
                    var sourcePose = source != null && skel.AnimRetargetSources != null && skel.AnimRetargetSources.TryGetValue(seq.RetargetSource, out var rp)
                        ? rp.ReferencePose : null;
                    byte[]? stream = codec switch
                    {
                        CUE4Parse.UE4.Assets.Exports.Animation.ACL.FACLCompressedAnimData acl => acl.CompressedByteStream,
                        _ => null,
                    };
                    var meta = new
                    {
                        seq.Name,
                        Package = path,
                        Codec = codec?.GetType().Name,
                        seq.NumFrames,
                        seq.SequenceLength,
                        seq.RateScale,
                        AdditiveAnimType = seq.AdditiveAnimType.ToString(),
                        EnableRootMotion = seq.GetOrDefault<bool>("bEnableRootMotion"),
                        Tracks = seq.GetTrackMap().Select(t => t.BoneTreeIndex).ToArray(),
                        RetargetSource = source,
                        RetargetModes = skel.BoneTree?.Select(m => m.ToString()).ToArray(),
                        RetargetPose = sourcePose?.Select(p => new
                        {
                            T = new[] { p.Translation.X, p.Translation.Y, p.Translation.Z },
                            R = new[] { p.Rotation.X, p.Rotation.Y, p.Rotation.Z, p.Rotation.W },
                        }).ToArray(),
                        Bones = refSkel.FinalRefBoneInfo.Select((b, i) => new
                        {
                            Name = b.Name.Text,
                            Parent = b.ParentIndex,
                            T = new[] { refSkel.FinalRefBonePose[i].Translation.X, refSkel.FinalRefBonePose[i].Translation.Y, refSkel.FinalRefBonePose[i].Translation.Z },
                            R = new[] { refSkel.FinalRefBonePose[i].Rotation.X, refSkel.FinalRefBonePose[i].Rotation.Y, refSkel.FinalRefBonePose[i].Rotation.Z, refSkel.FinalRefBonePose[i].Rotation.W },
                            S = new[] { refSkel.FinalRefBonePose[i].Scale3D.X, refSkel.FinalRefBonePose[i].Scale3D.Y, refSkel.FinalRefBonePose[i].Scale3D.Z },
                        }).ToArray(),
                    };
                    File.WriteAllText(Path.Combine(dir, seq.Name + ".json"), JsonConvert.SerializeObject(meta, Formatting.Indented));
                    if (stream != null) File.WriteAllBytes(Path.Combine(dir, seq.Name + ".acl"), stream);
                    Console.WriteLine($"raw  {seq.Name} codec={meta.Codec} frames={seq.NumFrames} bytes={stream?.Length ?? 0}");
                }
            }
            catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
        }
        break;
    }
    case "swf":
    {
        // Scaleform movies (SwfMovie.RawData, "GFX" signature) for JPEXS FFDec, plus the textures they import.
        var dir = Path.Combine(outRoot, "swf");
        Directory.CreateDirectory(dir);
        foreach (var path in matches.Where(p => p.EndsWith(".uasset")))
        {
            try
            {
                foreach (var obj in provider.LoadPackage(path).GetExports())
                {
                    if (obj.ExportType != "SwfMovie" && obj.ExportType != "FontLibrary" && !obj.Properties.Any(pp => pp.Name.Text == "RawData")) continue;
                    var raw = obj.GetOrDefault<byte[]>("RawData");
                    if (raw == null || raw.Length == 0) continue;
                    var dest = Path.Combine(dir, obj.Name + ".gfx");
                    File.WriteAllBytes(dest, raw);
                    Console.WriteLine($"swf  {obj.Name} {raw.Length} bytes");
                }
            }
            catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
        }
        break;
    }
    case "raw":
    {
        // Loose files as stored (ini, json, txt, uplugin...).
        foreach (var path in matches.Take(max))
        {
            try
            {
                var dest = Path.Combine(outRoot, "raw", path);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.WriteAllBytes(dest, provider.SaveAsset(path));
                Console.WriteLine($"raw  {path}");
            }
            catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
        }
        break;
    }
    default:
        Console.WriteLine($"unknown command {cmd}");
        return 1;
}
return 0;
