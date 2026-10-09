//! Every archetype converted from the local DI2 data must parse, and its survival rule must compile.
use gore_core::Archetype;

#[test]
fn converted_archetypes_load() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../game/data/archetypes.json");
    let Ok(src) = std::fs::read_to_string(&path) else {
        eprintln!("skipping: {} not generated", path.display());
        return;
    };
    let all: Vec<Archetype> = serde_json::from_str(&src).expect("archetypes.json parses");
    assert!(all.iter().any(|a| a.name == "Walker"));
    for a in &all {
        a.survive_expr().unwrap_or_else(|e| panic!("{}: {e}", a.name));
        assert!(!a.parts.is_empty(), "{} has parts", a.name);
    }
}
