///|
/// Result aliases for the skill store. MoonBit's parser reads the closing `>`
/// of `Result[Array[LocalStruct], String]` as an infix operator in this file,
/// so the nested generic is named once here.
pub type SkillRowsResult = Result[Array[SkillRow], String]

///|
pub type SkillAllowsResult = Result[Array[SkillAllowRow], String]

///|
pub type SkillKeysResult = Result[Array[SkillKeyRow], String]

///|
pub type SkillBindingsResult = Result[Array[SkillBindingRow], String]

///|
pub type SkillPermissionsResult = Result[Array[String]?, String]

///|
pub type SkillInvocationsResult = Result[Array[SkillInvocationRow], String]
