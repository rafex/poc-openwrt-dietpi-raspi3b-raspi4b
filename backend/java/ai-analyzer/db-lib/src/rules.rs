//! CRUD sobre `ai_rules` (plantillas de prompts y configuración dinámica).

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring, string_to_raw},
};

/// Inserta o actualiza una regla.
/// Devuelve 1 en éxito, 0 en error.
///
/// # Safety
/// Todos los punteros deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn rule_upsert(
    handle:     *mut DbHandle,
    key:        *const c_char,
    value:      *const c_char,
    updated_at: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let k  = match cstr_to_str(key)        { Some(s) => s, None => { set_last_error("key nulo"); return 0; } };
    let v  = match cstr_to_str(value)      { Some(s) => s, None => { set_last_error("value nulo"); return 0; } };
    let ua = match cstr_to_str(updated_at) { Some(s) => s, None => { set_last_error("updated_at nulo"); return 0; } };

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO ai_rules (key, value, updated_at) VALUES (?1, ?2, ?3) \
         ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        rusqlite::params![k, v, ua],
    ) {
        Ok(_) => 1,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve el valor de una regla como `*mut c_char`, o NULL si no existe.
///
/// # Safety
/// `handle` y `key` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn rule_get(
    handle: *mut DbHandle,
    key:    *const c_char,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let k = match cstr_to_str(key) {
        Some(s) => s,
        None => { set_last_error("key nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    match conn.query_row("SELECT value FROM ai_rules WHERE key=?1", rusqlite::params![k], |r| r.get::<_, String>(0)) {
        Ok(v) => string_to_raw(v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve todas las reglas como JSON array `[{"key":"...","value":"...","updated_at":"..."}]`.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn rule_list(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT key, value, updated_at FROM ai_rules ORDER BY key"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map([], |row| {
        Ok(serde_json::json!({
            "key":        row.get::<_, String>(0)?,
            "value":      row.get::<_, String>(1)?,
            "updated_at": row.get::<_, String>(2)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Borra una regla por clave. Devuelve 1 si existía, 0 si no, -1 en error.
///
/// # Safety
/// `handle` y `key` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn rule_delete(
    handle: *mut DbHandle,
    key:    *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let k = match cstr_to_str(key) {
        Some(s) => s,
        None => { set_last_error("key nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.execute("DELETE FROM ai_rules WHERE key=?1", rusqlite::params![k]) {
        Ok(n) => n as i64,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}
