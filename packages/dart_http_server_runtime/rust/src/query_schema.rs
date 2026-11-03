//! Scalar query conversion for validation only. The original URL pairs remain
//! strings when dispatched to Dart and its existing query decoder callbacks.

use std::collections::{HashMap, HashSet};

use serde_json::{Number, Value};

#[derive(Clone, Copy, PartialEq, Eq)]
enum ScalarType {
    String,
    Integer,
    Number,
    Boolean,
}

#[derive(Default)]
pub(crate) struct QuerySchema {
    fields: HashMap<String, ScalarType>,
}

impl QuerySchema {
    pub(crate) fn compile(schema: &Value, registry: &Value) -> Self {
        let mut result = Self::default();
        result.collect_fields(schema, registry, &mut HashSet::new());
        result
    }

    fn collect_fields(&mut self, schema: &Value, registry: &Value, visiting: &mut HashSet<String>) {
        if visiting.len() >= 64 {
            return;
        }
        if let Some(reference) = schema.get("$ref").and_then(Value::as_str)
            && visiting.insert(reference.to_owned())
        {
            if let Some(target) = resolve_reference(reference, registry) {
                self.collect_fields(target, registry, visiting);
            }
            visiting.remove(reference);
        }
        if let Some(parts) = schema.get("allOf").and_then(Value::as_array) {
            for part in parts {
                self.collect_fields(part, registry, visiting);
            }
        }
        if let Some(properties) = schema.get("properties").and_then(Value::as_object) {
            for (name, property) in properties {
                if let Some(kind) = scalar_type(property, registry, &mut HashSet::new()) {
                    self.fields
                        .entry(name.clone())
                        .and_modify(|existing| {
                            if *existing != kind {
                                // Conflicting declarations have no unambiguous wire
                                // type. Leave their interpretation to the validator.
                                *existing = ScalarType::String;
                            }
                        })
                        .or_insert(kind);
                }
            }
        }
    }

    pub(crate) fn convert(&self, values: &HashMap<String, String>) -> Value {
        Value::Object(
            values
                .iter()
                .map(|(name, value)| {
                    let converted = match self.fields.get(name) {
                        Some(ScalarType::Integer) => {
                            value.trim().parse::<i64>().ok().map(Value::from)
                        }
                        Some(ScalarType::Number) => serde_json::from_str::<Number>(value)
                            .ok()
                            .map(Value::Number),
                        Some(ScalarType::Boolean) => match value.as_str() {
                            "true" => Some(Value::Bool(true)),
                            "false" => Some(Value::Bool(false)),
                            _ => None,
                        },
                        _ => None,
                    };
                    // Invalid scalar syntax stays a string and is rejected by
                    // the original schema, with the normal validation response.
                    (
                        name.clone(),
                        converted.unwrap_or_else(|| Value::String(value.clone())),
                    )
                })
                .collect(),
        )
    }
}

fn resolve_reference<'a>(reference: &str, registry: &'a Value) -> Option<&'a Value> {
    let reference = reference
        .strip_prefix(super::SCHEMA_REGISTRY_URI)
        .unwrap_or(reference);
    match reference.strip_prefix('#') {
        Some(pointer) => registry.pointer(pointer),
        None => registry.get("components")?.get("schemas")?.get(reference),
    }
}

fn scalar_type(
    schema: &Value,
    registry: &Value,
    visiting: &mut HashSet<String>,
) -> Option<ScalarType> {
    if visiting.len() >= 64 {
        return None;
    }
    if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        if !visiting.insert(reference.to_owned()) {
            return None;
        }
        let result = resolve_reference(reference, registry)
            .and_then(|target| scalar_type(target, registry, visiting));
        visiting.remove(reference);
        return result;
    }
    if let Some(kind) = schema.get("type") {
        return match kind {
            Value::String(kind) => scalar_name(kind),
            Value::Array(kinds) => {
                let mut concrete = kinds.iter().filter(|kind| kind.as_str() != Some("null"));
                let kind = scalar_name(concrete.next()?.as_str()?)?;
                concrete.next().is_none().then_some(kind)
            }
            _ => None,
        };
    }
    for keyword in ["anyOf", "oneOf"] {
        if let Some(parts) = schema.get(keyword).and_then(Value::as_array) {
            let mut result = None;
            for part in parts {
                if part.get("type").and_then(Value::as_str) == Some("null") {
                    continue;
                }
                let kind = scalar_type(part, registry, visiting)?;
                if result.is_some_and(|existing| existing != kind) {
                    return None;
                }
                result = Some(kind);
            }
            return result;
        }
    }
    if let Some(parts) = schema.get("allOf").and_then(Value::as_array) {
        let mut result = None;
        for part in parts {
            if let Some(kind) = scalar_type(part, registry, visiting) {
                if result.is_some_and(|existing| existing != kind) {
                    return None;
                }
                result = Some(kind);
            }
        }
        return result;
    }
    None
}

fn scalar_name(name: &str) -> Option<ScalarType> {
    match name {
        "string" => Some(ScalarType::String),
        "integer" => Some(ScalarType::Integer),
        "number" => Some(ScalarType::Number),
        "boolean" => Some(ScalarType::Boolean),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn validates_the_converted_object_against_the_original_schema() {
        let schema = json!({"type": "object", "properties": {
            "offset": {"type": "integer", "minimum": 0, "maximum": 100000}
        }, "required": ["offset"], "additionalProperties": false});
        let validator = jsonschema::options().build(&schema).unwrap();
        let raw = json!({"offset": "0"});
        // Reproduce the original rejection before the query conversion step.
        assert!(!validator.is_valid(&raw));
        assert!(
            validator
                .iter_errors(&raw)
                .next()
                .unwrap()
                .to_string()
                .contains("integer")
        );
        let plan = QuerySchema::compile(&schema, &Value::Null);
        assert!(validator.is_valid(&plan.convert(&HashMap::from([("offset".into(), "0".into())]))));
        for value in ["-1", "100001", "invalid"] {
            assert!(
                !validator
                    .is_valid(&plan.convert(&HashMap::from([("offset".into(), value.into())])))
            );
        }
        assert!(!validator.is_valid(&plan.convert(&HashMap::new())));
    }

    #[test]
    fn converts_scalars_without_changing_raw_values() {
        let schema = json!({"properties": {
            "offset": {"type": "integer"}, "ratio": {"type": "number"},
            "enabled": {"type": "boolean"}, "cursor": {"type": "string"}
        }});
        let raw = HashMap::from([
            ("offset".into(), "0".into()),
            ("ratio".into(), "0.5".into()),
            ("enabled".into(), "false".into()),
            ("cursor".into(), "00042".into()),
        ]);
        let plan = QuerySchema::compile(&schema, &Value::Null);
        assert_eq!(
            plan.convert(&raw),
            json!({"offset": 0, "ratio": 0.5, "enabled": false, "cursor": "00042"})
        );
        assert_eq!(raw["offset"], "0");
    }

    #[test]
    fn resolves_root_property_aliases_and_nullable_scalars() {
        let registry = json!({"components": {"schemas": {
            "Offset": {"type": ["integer", "null"]},
            "Alias": {"$ref": "#/components/schemas/Offset"},
            "Query": {"type": "object", "properties": {
                "offset": {"$ref": "#/components/schemas/Alias"},
                "enabled": {"anyOf": [{"type": "boolean"}, {"type": "null"}]}
            }}
        }}});
        let schema = json!({"$ref": "#/components/schemas/Query"});
        let plan = QuerySchema::compile(&schema, &registry);
        assert_eq!(
            plan.convert(&HashMap::from([
                ("offset".into(), "50".into()),
                ("enabled".into(), "true".into()),
            ])),
            json!({"offset": 50, "enabled": true})
        );
        assert_eq!(plan.convert(&HashMap::new()), json!({}));
        assert_eq!(
            plan.convert(&HashMap::from([("offset".into(), "null".into())])),
            json!({"offset": "null"})
        );
    }

    #[test]
    fn invalid_values_overflow_and_unknown_fields_remain_for_schema_validation() {
        let schema = json!({"properties": {
            "offset": {"type": "integer"}, "ratio": {"type": "number"},
            "enabled": {"type": "boolean"}
        }});
        let plan = QuerySchema::compile(&schema, &Value::Null);
        for (name, value) in [
            ("offset", ""),
            ("offset", "1.5"),
            ("offset", "9223372036854775808"),
            ("ratio", "NaN"),
            ("ratio", "1e999"),
            ("enabled", "yes"),
            ("unknown", "0"),
        ] {
            assert_eq!(
                plan.convert(&HashMap::from([(name.into(), value.into())])),
                json!({name: value})
            );
        }
    }

    #[test]
    fn leaves_ambiguous_and_structured_types_as_strings_and_stops_reference_cycles() {
        let registry =
            json!({"components": {"schemas": {"Cycle": {"$ref": "#/components/schemas/Cycle"}}}});
        let schema = json!({"properties": {
            "mixed": {"anyOf": [{"type": "integer"}, {"type": "string"}]},
            "array": {"type": "array"}, "cycle": {"$ref": "#/components/schemas/Cycle"}
        }});
        let raw = HashMap::from([
            ("mixed".into(), "0".into()),
            ("array".into(), "[]".into()),
            ("cycle".into(), "0".into()),
        ]);
        assert_eq!(
            QuerySchema::compile(&schema, &registry).convert(&raw),
            json!({"mixed": "0", "array": "[]", "cycle": "0"})
        );
    }
}
