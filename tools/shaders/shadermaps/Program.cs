// shadermaps: maps DI2's shader types to their compiled code in the user's own install (local only, never shared).
//
//   shadermaps names <candidates.txt>                         -> prints FHashedName hash for each line (sanity)
//   shadermaps global <GlobalShaderCache.bin> <names.txt> <out.json>
//       Every global shader map section: HashedSourceFilename, ResourceHash (= a shadermap hash of
//       ShaderArchive-Global), and per shader its type / permutation / ResourceIndex (index into that shadermap's
//       shader list in the archive) / bindings.
//   shadermaps material <ushaderresources> <names.txt> <out_dir> <regex>
//       Materials / material instances matching regex: DI2 stores a 20-byte hash in place of the inline shader maps
//       (CUE4Parse: UMaterialInstance.CustomGameData); the hash keys the .ushaderresources table, whose blob is the
//       usual inline-shader-map stream (int32 count + FMaterialResource inline shader maps, names as FStrings).
// names.txt: candidate type names (from tools/shaders/exe_strings.py); each is registered with CUE4Parse's
// HashedNamesProvider so FHashedName values print as names.
using System.Text.RegularExpressions;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.UE4.Assets.Exports.Material;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Readers;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

const string Paks = @"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Content\Paks";
const string Root = @".";
var version = new VersionContainer(EGame.GAME_DeadIsland2);

void LoadNames(string path)
{
    int n = 0;
    foreach (var l in File.ReadLines(path))
    {
        var s = l.Trim();
        if (s.Length > 0 && HashedNamesProvider.TryAdd(s)) n++;
    }
    Console.Error.WriteLine($"{n} candidate names registered");
}

switch (args[0])
{
    case "hash":
    {
        // FHashedName as CUE4Parse's HashedNamesProvider computes it: CityHash64WithSeed(UPPER(name), number+1)
        // for "Name_<number>", else seed 0. Writes "<hash hex>	<name>" lines.
        using var w = new StreamWriter(args[2]);
        foreach (var l in File.ReadLines(args[1]))
        {
            var line = l.Trim();
            if (line.Length == 0) continue;
            var ind = line.LastIndexOf('_');
            var span = line.AsSpan()[(ind + 1)..];
            ulong hash;
            if (ind > 0 && span.Length > 0 && int.TryParse(span, out var index) && ((index == 0 && span.Length == 1) || (index > 0 && span[0] != '0')))
                hash = CUE4Parse.Utils.CityHash.CityHash64WithSeed(System.Text.Encoding.UTF8.GetBytes(line[..ind].ToUpperInvariant()), (ulong) (index + 1));
            else
                hash = CUE4Parse.Utils.CityHash.CityHash64WithSeed(System.Text.Encoding.UTF8.GetBytes(line.ToUpperInvariant()), 0);
            w.WriteLine($"{hash:x16}	{line}");
        }
        break;
    }
    case "global":
    {
        LoadNames(args[2]);
        var bytes = File.ReadAllBytes(args[1]);
        var cache = new FGlobalShaderCache(new FByteArchive("GlobalShaderCache", bytes, version));
        File.WriteAllText(args[3], JsonConvert.SerializeObject(cache, Formatting.Indented));
        Console.WriteLine($"{cache.LoadedShaderMaps.Length} global shader map sections -> {args[3]}");
        break;
    }
    case "material":
    {
        LoadNames(args[2]);
        // .ushaderresources: u32 version(2), u32 count, {FSHAHash, u64 offset, u32 size}[count], blobs.
        var res = File.ReadAllBytes(args[1]);
        var count = BitConverter.ToInt32(res, 4);
        var table = new Dictionary<string, (long off, int size)>();
        var p = 8;
        for (var i = 0; i < count; i++, p += 32)
            table[Convert.ToHexString(res, p, 20)] = ((long) BitConverter.ToUInt64(res, p + 20), BitConverter.ToInt32(res, p + 28));
        var dataStart = p;

        var toolDir = Path.Combine(Root, "tools", "di2x", "bin", "out");
        var oodlePath = Path.Combine(toolDir, OodleHelper.OodleFileName);
        OodleHelper.Initialize(oodlePath);
        ZlibHelper.Initialize(Path.Combine(toolDir, ZlibHelper.DllName));
        var provider = new DefaultFileProvider(Paks, SearchOption.TopDirectoryOnly, version);
        provider.ReadShaderMaps = true;
        provider.Initialize();
        provider.SubmitKey(new FGuid(), new FAesKey(File.ReadAllText(Path.Combine(Root, "recon", "aes_key.txt")).Trim()));
        provider.PostMount();
        var rx = new Regex(args[4], RegexOptions.IgnoreCase);
        var outDir = args[3];
        Directory.CreateDirectory(outDir);
        foreach (var path in provider.Files.Keys.Where(k => k.EndsWith(".uasset") && rx.IsMatch(k)).OrderBy(k => k))
        {
            try
            {
                foreach (var e in provider.LoadPackage(path).GetExports())
                {
                    if (e is not UMaterialInterface mi) continue;
                    var j = new JObject { ["path"] = path, ["export"] = e.Name, ["class"] = e.ExportType };
                    if (e.CustomGameData is FSHAHash h)
                    {
                        var key = h.ToString().ToUpperInvariant();
                        j["shader_resource_hash"] = key;
                        if (table.TryGetValue(key, out var loc))
                        {
                            var blob = new byte[loc.size];
                            Array.Copy(res, dataStart + loc.off, blob, 0, loc.size);
                            var ar = new FByteArchive("ushaderresources", blob, version);
                            var n = ar.Read<int>();
                            var proxy = new FMaterialResourceProxyReader(ar, false);
                            var list = new List<FMaterialResource>();
                            for (var r = 0; r < n; r++)
                            {
                                var m = new FMaterialResource();
                                m.DeserializeInlineShaderMap(proxy);
                                list.Add(m);
                            }
                            j["consumed"] = $"{ar.Position}/{blob.Length}";
                            j["resources"] = JToken.FromObject(list, JsonSerializer.Create(new JsonSerializerSettings { Formatting = Formatting.Indented }));
                        }
                        else j["error"] = "hash not in ushaderresources";
                    }
                    else if (mi.LoadedMaterialResources.Count > 0)
                        j["resources"] = JToken.FromObject(mi.LoadedMaterialResources);
                    j["properties"] = JToken.Parse(JsonConvert.SerializeObject(e));
                    var dest = Path.Combine(outDir, e.Name + ".json");
                    File.WriteAllText(dest, j.ToString(Formatting.Indented));
                    Console.WriteLine($"ok   {path} {e.Name} {j["consumed"]}");
                }
            }
            catch (Exception ex) { Console.WriteLine($"FAIL {path}: {ex.GetType().Name}: {ex.Message}"); }
        }
        break;
    }
}
