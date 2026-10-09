//! Skeleton topology and the mapping from bones to gameplay body parts.

use serde::{Deserialize, Serialize};

/// Bone hierarchy as the engine sees it (names + parent indices).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Skeleton {
    pub names: Vec<String>,
    pub parents: Vec<Option<usize>>,
}

impl Skeleton {
    pub fn new(names: Vec<String>, parents: Vec<Option<usize>>) -> Self {
        assert_eq!(names.len(), parents.len());
        Self { names, parents }
    }

    pub fn len(&self) -> usize {
        self.names.len()
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }

    pub fn find(&self, name: &str) -> Option<usize> {
        self.names.iter().position(|n| n.eq_ignore_ascii_case(name))
    }

    /// True when `bone` is `ancestor` or lies below it.
    pub fn is_in_subtree(&self, mut bone: usize, ancestor: usize) -> bool {
        loop {
            if bone == ancestor {
                return true;
            }
            match self.parents[bone] {
                Some(p) => bone = p,
                None => return false,
            }
        }
    }

    /// `root` and every bone below it.
    pub fn subtree(&self, root: usize) -> Vec<usize> {
        (0..self.len()).filter(|&b| self.is_in_subtree(b, root)).collect()
    }

    /// Walks from `bone` towards the root, yielding `bone` first.
    pub fn ancestry(&self, bone: usize) -> impl Iterator<Item = usize> + '_ {
        std::iter::successors(Some(bone), move |&b| self.parents[b])
    }
}

/// What a part means for gameplay facts (HasBothArms, crawler locomotion, ...).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PartRole {
    Head,
    ArmLeft,
    ArmRight,
    LegLeft,
    LegRight,
    Torso,
    Other,
}

impl PartRole {
    /// Infers the role from a DI2 part id such as `arm_left`, `Leg_Right`, `Torso_Bisectable`.
    pub fn from_id(id: &str) -> Self {
        let l = id.to_ascii_lowercase();
        let left = l.contains("left") || l.ends_with("_l");
        if l.contains("head") {
            PartRole::Head
        } else if l.contains("arm") {
            if left {
                PartRole::ArmLeft
            } else {
                PartRole::ArmRight
            }
        } else if l.contains("leg") {
            if left {
                PartRole::LegLeft
            } else {
                PartRole::LegRight
            }
        } else if l.contains("torso") || l.contains("chest") {
            PartRole::Torso
        } else {
            PartRole::Other
        }
    }

    pub fn is_arm(self) -> bool {
        matches!(self, PartRole::ArmLeft | PartRole::ArmRight)
    }

    pub fn is_leg(self) -> bool {
        matches!(self, PartRole::LegLeft | PartRole::LegRight)
    }
}
