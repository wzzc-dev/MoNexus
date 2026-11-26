///|
/// Result aliases for manifest parsing.
///
/// MoonBit's parser rejects `Result[@pkg.Struct, E]` in some function return
/// positions of this file (it reads `>` as an infix operator). Naming the
/// aliases here keeps the parser on the type path.
pub type SkillSourceResult = Result[@contracts.SkillSource, SkillFault]

///|
pub type SkillSignatureResult = Result[@contracts.SkillSignature, SkillFault]

///|
pub type SkillLimitsResult = Result[@contracts.SkillLimits, SkillFault]

///|
pub type SkillManifestResult = Result[@contracts.SkillManifest, SkillFault]
