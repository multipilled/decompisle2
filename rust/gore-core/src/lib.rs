//! gore-core: an engine-agnostic recreation of a FLESH-style gore and zombie system.
//!
//! - [`health::Body`]: per-limb health, breaking, dismemberment, crawler and death rules
//!   (data-driven by [`archetype::Archetype`], e.g. DI2's Walker).
//! - [`wounds::WoundField`]: capsule wounds in bind-pose space that shaders turn into layered gore.
//! - [`brain::Brain`]: zombie perception, chase, attack cards, stagger and crawling.
//! - [`expr::Expr`]: DI2-style knowledge-base expressions for survival rules.
//!
//! Hosts (Godot, Bevy, Unreal, ...) map their skeleton into [`anatomy::Skeleton`], convert hit
//! points into bind-pose space and render the outcomes.

pub mod anatomy;
pub mod archetype;
pub mod brain;
pub mod damage;
pub mod dismember;
pub mod expr;
pub mod health;
pub mod splatter;
pub mod splatter_rt;
pub mod stability;
pub mod status;
pub mod wounds;

pub use anatomy::{PartRole, Skeleton};
pub use archetype::Archetype;
pub use brain::{Anim, Brain, Command, Perception};
pub use damage::{DamageKind, Hit};
pub use health::{Body, Outcome, PartState};
pub use splatter::{Splatter, Stamp};
pub use stability::{Reaction, Stability};
pub use status::{Status, StatusEffects};
pub use wounds::{WoundChannel, WoundField, WoundScale};
pub use glam;
