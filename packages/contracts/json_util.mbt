///|
/// Small helpers around `moonbitlang/core/json` shared by the RPC, event,
/// method and discovery code. Encoding uses the public `Json` constructors;
/// decoding uses pattern matching so no `@json` deprecation shims leak into
/// the rest of the codebase.
pub fn json_object(entries : Array[(String, @json.Json)]) -> @json.Json {
  let map : Map[String, @json.Json] = Map([])
  for pair in entries {
    let (key, value) = pair
    map.set(key, value)
  }
  @json.Json::object(map)
}

///|
pub fn json_string(value : String) -> @json.Json {
  @json.Json::string(value)
}

///|
pub fn json_bool(value : Bool) -> @json.Json {
  @json.Json::boolean(value)
}

///|
pub fn json_int(value : Int) -> @json.Json {
  @json.Json::number(value.to_double())
}

///|
pub fn json_int64(value : Int64) -> @json.Json {
  @json.Json::number(value.to_double())
}

///|
pub fn json_null() -> @json.Json {
  @json.Json::null()
}

///|
pub fn json_array(items : Array[@json.Json]) -> @json.Json {
  @json.Json::array(items)
}

///|
pub fn as_object(json : @json.Json) -> Map[String, @json.Json]? {
  match json {
    @json.Json::Object(map) => Some(map)
    _ => None
  }
}

///|
pub fn as_string(json : @json.Json) -> String? {
  match json {
    @json.Json::String(value) => Some(value)
    _ => None
  }
}

///|
pub fn as_bool(json : @json.Json) -> Bool? {
  match json {
    @json.Json::True => Some(true)
    @json.Json::False => Some(false)
    _ => None
  }
}

///|
pub fn as_int64(json : @json.Json) -> Int64? {
  match json {
    @json.Json::Number(value, ..) => Some(value.to_int64())
    _ => None
  }
}

///|
pub fn as_int(json : @json.Json) -> Int? {
  match as_int64(json) {
    Some(value) => Some(value.to_int())
    None => None
  }
}

///|
pub fn field(
  object : Map[String, @json.Json],
  key : String,
) -> @json.Json? {
  object.get(key)
}

///|
pub fn string_field(
  object : Map[String, @json.Json],
  key : String,
) -> String? {
  match object.get(key) {
    Some(value) => as_string(value)
    None => None
  }
}

///|
pub fn string_field_or(
  object : Map[String, @json.Json],
  key : String,
  default : String,
) -> String {
  match string_field(object, key) {
    Some(value) => value
    None => default
  }
}

///|
pub fn int_field(object : Map[String, @json.Json], key : String) -> Int? {
  match object.get(key) {
    Some(value) => as_int(value)
    None => None
  }
}

///|
pub fn int_field_or(
  object : Map[String, @json.Json],
  key : String,
  default : Int,
) -> Int {
  match int_field(object, key) {
    Some(value) => value
    None => default
  }
}

///|
pub fn int64_field(
  object : Map[String, @json.Json],
  key : String,
) -> Int64? {
  match object.get(key) {
    Some(value) => as_int64(value)
    None => None
  }
}

///|
pub fn int64_field_or(
  object : Map[String, @json.Json],
  key : String,
  default : Int64,
) -> Int64 {
  match int64_field(object, key) {
    Some(value) => value
    None => default
  }
}

///|
pub fn bool_field_or(
  object : Map[String, @json.Json],
  key : String,
  default : Bool,
) -> Bool {
  match object.get(key) {
    Some(value) => match as_bool(value) {
      Some(found) => found
      None => default
    }
    None => default
  }
}
