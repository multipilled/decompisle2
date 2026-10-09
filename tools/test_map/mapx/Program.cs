// mapx: one pak mount for tools/build_test_map.py (personal use; the user's own install, output stays local).
//   mapx <root> <meshes.txt> <textures.txt> <out_dir>
//     meshes.txt   static mesh package paths -> <out_dir>/mesh/<package path>.glb (CUE4Parse glTF writer, LOD0, no materials)
//     textures.txt texture package paths     -> <out_dir>/mips/<name>.mips + meta.json: every cooked mip from the first
//                  streamed-in one, byte for byte (same layout as tools/build_dani_materials.py MIPDUMP_CS)
//   mapx <root> scan <regex> <out.txt>: .umap packages whose name table matches (e.g. an actor class)
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports.StaticMesh;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using Newtonsoft.Json;

const string Paks = @"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Content\Paks";
var root = args[0]; var outDir = args[3];
var toolDir = Path.Combine(root, "tools", "di2x", "bin", "out");
OodleHelper.Initialize(Path.Combine(toolDir, OodleHelper.OodleFileName));
ZlibHelper.Initialize(Path.Combine(toolDir, ZlibHelper.DllName));
var provider = new DefaultFileProvider(Paks, SearchOption.TopDirectoryOnly, new VersionContainer(EGame.GAME_DeadIsland2));
provider.Initialize();
provider.SubmitKey(new FGuid(), new FAesKey(File.ReadAllText(Path.Combine(root, "recon", "aes_key.txt")).Trim()));
provider.PostMount();

if (args[1] == "scan")
{
    // mapx <root> scan <regex> <out.txt>: every .umap whose name table matches (class / property / object names).
    var rx = new System.Text.RegularExpressions.Regex(args[2], System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    // optional 5th arg: package path regex (default: every .umap)
    var prx = new System.Text.RegularExpressions.Regex(args.Length > 4 ? args[4] : @"\.umap$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    var maps = provider.Files.Keys.Where(k => prx.IsMatch(k) && (k.EndsWith(".umap") || k.EndsWith(".uasset"))).OrderBy(k => k).ToList();
    using var w = new StreamWriter(args[3]);
    var n = 0;
    foreach (var path in maps)
    {
        try
        {
            var pkg = provider.LoadPackage(path);
            var hits = pkg.NameMap.Select(x => x.Name).Where(x => rx.IsMatch(x)).Distinct().ToList();
            if (hits.Count > 0) { w.WriteLine($"{path}	{string.Join(",", hits)}"); n++; }
        }
        catch (Exception e) { w.WriteLine($"FAIL {path}: {e.Message}"); }
    }
    Console.WriteLine($"scanned {maps.Count} maps, {n} match");
    return 0;
}

if (args[1] == "matres")
{
    // mapx <root> matres <.ushaderresources> <key> <out.json>: the inline shader map(s) stored under one key, in the
    // same JSON shape as tools/shaders/shadermaps.exe "material" ("resources"), for keys of level-cooked material
    // instances that shadermaps.exe does not visit (it reads .uasset packages only). Same reader code as shadermaps.
    var res = File.ReadAllBytes(args[2]);
    var count = BitConverter.ToInt32(res, 4);
    var p = 8;
    long off = -1; var size = 0;
    for (var i = 0; i < count; i++, p += 32)
        if (Convert.ToHexString(res, p, 20) == args[3].ToUpperInvariant())
        { off = (long) BitConverter.ToUInt64(res, p + 20); size = BitConverter.ToInt32(res, p + 28); }
    var dataStart = 8 + count * 32;
    if (off < 0) { Console.WriteLine("key not found"); return 1; }
    provider.ReadShaderMaps = true;
    var blob = new byte[size];
    Array.Copy(res, dataStart + off, blob, 0, size);
    var ar = new CUE4Parse.UE4.Readers.FByteArchive("ushaderresources", blob, provider.Versions);
    var n = ar.Read<int>();
    var proxy = new CUE4Parse.UE4.Assets.Exports.Material.FMaterialResourceProxyReader(ar, false);
    var list = new List<CUE4Parse.UE4.Assets.Exports.Material.FMaterialResource>();
    for (var r = 0; r < n; r++)
    {
        var m = new CUE4Parse.UE4.Assets.Exports.Material.FMaterialResource();
        m.DeserializeInlineShaderMap(proxy);
        list.Add(m);
    }
    var j = new Newtonsoft.Json.Linq.JObject { ["path"] = "key " + args[3], ["export"] = args[3], ["shader_resource_hash"] = args[3],
        ["consumed"] = $"{ar.Position}/{blob.Length}",
        ["resources"] = Newtonsoft.Json.Linq.JToken.FromObject(list, JsonSerializer.Create(new JsonSerializerSettings { Formatting = Formatting.Indented })) };
    File.WriteAllText(args[4], j.ToString(Formatting.Indented));
    return 0;
}

if (args[1] == "matkeys")
{
    // mapx <root> matkeys <package> <out.tsv>: every material interface export of a package (also .umap-cooked ones,
    // e.g. LandscapeMaterialInstanceConstants) with its Outer and its .ushaderresources key (DI2 CustomGameData).
    provider.ReadShaderMaps = true;
    using var w = new StreamWriter(args[3]);
    foreach (var e in provider.LoadPackage(args[2]).GetExports())
    {
        if (e is not CUE4Parse.UE4.Assets.Exports.Material.UMaterialInterface) continue;
        w.WriteLine($"{e.Outer?.Name}\t{e.Name}\t{e.ExportType}\t{e.CustomGameData}");
    }
    return 0;
}

var meshes = File.ReadAllLines(args[1]).Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
if (meshes.Count > 0)
{
    var session = new ExportSession();
    var queued = 0;
    foreach (var path in meshes)
    {
        try
        {
            foreach (var obj in provider.LoadPackage(path).GetExports())
                if (obj is UStaticMesh) { session.Add(obj); queued++; }
        }
        catch (Exception e) { Console.WriteLine($"FAIL {path}: {e.GetType().Name}: {e.Message}"); }
    }
    var options = new ExportOptions(meshFormat: EMeshFormat.Gltf2, textureFormat: ETextureFormat.Png,
        exportHdrTexturesAsHdr: false, exportMaterials: false, exportMorphTargets: false);
    var results = await session.RunAsync(Path.Combine(outDir, "mesh"), options);
    Console.WriteLine($"mesh queued {queued}, results {results.Count()}");
    foreach (var r in results) Console.WriteLine($"mesh {r}");
}

var textures = File.ReadAllLines(args[2]).Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
var mipDir = Path.Combine(outDir, "mips"); Directory.CreateDirectory(mipDir);
var meta = new List<object>();
foreach (var path in textures)
{
    try
    {
        foreach (var e in provider.LoadPackage(path).GetExports())
        {
            if (e is not UTexture2D t) continue;
            // textures cooked into a level (landscape height / weight maps) share export names across actors: Outer.Name
            var tname = path.EndsWith(".umap") && e.Outer != null ? e.Outer.Name + "." + e.Name : e.Name;
            var pd = t.PlatformData; var first = t.GetFirstMipIndex();
            var mips = new List<object>();
            using var fs = File.Create(Path.Combine(mipDir, tname + ".mips"));
            for (var i = first; i < pd.Mips.Length; i++)
            {
                var data = pd.Mips[i].BulkData?.Data;
                if (data == null) break;
                fs.Write(data, 0, data.Length);
                mips.Add(new { w = pd.Mips[i].SizeX, h = pd.Mips[i].SizeY, d = pd.Mips[i].SizeZ, bytes = data.Length });
            }
            meta.Add(new {
                name = tname, path, cls = e.ExportType, pixel_format = t.Format.ToString(),
                srgb = t.SRGB, address = new[] { t.GetTextureAddressX().ToString(), t.GetTextureAddressY().ToString() },
                filter = t.Filter.ToString(), lod_group = t.LODGroup.ToString(), compression = t.CompressionSettings.ToString(),
                first_mip = first, total_mips = pd.Mips.Length, mips,
            });
            Console.WriteLine($"tex  {tname} {t.Format} mips {mips.Count}/{pd.Mips.Length - first}");
        }
    }
    catch (Exception ex) { Console.WriteLine($"FAIL {path}: {ex.Message}"); }
}
File.WriteAllText(Path.Combine(mipDir, "meta.json"), JsonConvert.SerializeObject(meta, Formatting.Indented));
return 0;
