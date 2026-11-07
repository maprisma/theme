use serde::Deserialize;
use std::collections::BTreeMap;
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Automation {
    pub workspace_events: bool,
    pub tick: bool,
    pub tiling: Tiling,
    pub autostart: bool,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Tiling {
    pub active: bool,
    pub default_limit: usize,
    pub limits: BTreeMap<usize, usize>,
    pub floating: Vec<usize>,
    pub tiled: Vec<usize>,
}
impl Default for Tiling {
    fn default() -> Self {
        Self {
            active: false,
            default_limit: 2,
            limits: BTreeMap::new(),
            floating: vec![],
            tiled: vec![],
        }
    }
}
impl Tiling {
    pub fn limit(&self, index: usize) -> usize {
        self.limits
            .get(&index)
            .copied()
            .unwrap_or(self.default_limit)
            .clamp(1, 4)
    }
}
/// Counts include the new window. Search forward, wrapping once; never create workspaces.
pub fn overflow(source: usize, counts: &BTreeMap<usize, usize>, tiling: &Tiling) -> Option<usize> {
    if !tiling.active || counts.get(&source).copied().unwrap_or(0) <= tiling.limit(source) {
        return None;
    }
    counts
        .range((source + 1)..)
        .chain(counts.range(..source))
        .find(|(i, n)| **n < tiling.limit(**i))
        .map(|(i, _)| *i)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse() {
        let a:Automation=serde_json::from_str(r#"{"workspace_events":true,"tick":true,"tiling":{"active":true,"default_limit":2,"limits":{"3":1},"floating":[5],"tiled":[1,2]},"autostart":true}"#).unwrap();
        assert!(a.tick && a.autostart && a.workspace_events);
        assert_eq!(a.tiling.limit(3), 1);
        assert_eq!(a.tiling.floating, vec![5]);
    }
    #[test]
    fn overflow_decision() {
        let t = Tiling {
            active: true,
            ..Default::default()
        };
        let c = BTreeMap::from([(1, 3), (2, 2), (3, 0)]);
        assert_eq!(overflow(1, &c, &t), Some(3));
        assert_eq!(overflow(2, &c, &t), None);
        assert_eq!(overflow(1, &BTreeMap::from([(1, 3), (2, 2)]), &t), None);
    }
}
