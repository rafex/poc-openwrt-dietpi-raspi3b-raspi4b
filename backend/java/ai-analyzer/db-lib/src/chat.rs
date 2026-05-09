//! CRUD sobre `chat_sessions` y `chat_messages`.

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring},
};

// ──────────────────────────────────────────────────────────────────────────────
// chat_sessions
// ──────────────────────────────────────────────────────────────────────────────

/// Crea o actualiza una sesión de chat.
///
/// Si `session_id` ya existe actualiza `updated_at`; si no existe la inserta.
/// Devuelve 1 en éxito, 0 en error.
///
/// # Safety
/// Todos los punteros deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn chat_session_upsert(
    handle:     *mut DbHandle,
    session_id: *const c_char,
    now_iso:    *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let sid = match cstr_to_str(session_id) {
        Some(s) => s,
        None => { set_last_error("session_id nulo"); return 0; }
    };
    let now = match cstr_to_str(now_iso) {
        Some(s) => s,
        None => { set_last_error("now_iso nulo"); return 0; }
    };

    let conn = h.conn.lock();
    let r = conn.execute(
        "INSERT INTO chat_sessions (session_id, created_at, updated_at) \
         VALUES (?1, ?2, ?2) \
         ON CONFLICT(session_id) DO UPDATE SET updated_at=excluded.updated_at",
        rusqlite::params![sid, now],
    );
    match r {
        Ok(_) => 1,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve todas las sesiones como JSON array (id, created_at, updated_at).
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn chat_session_list(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT session_id, created_at, updated_at FROM chat_sessions ORDER BY updated_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map([], |row| {
        Ok(serde_json::json!({
            "session_id": row.get::<_, String>(0)?,
            "created_at": row.get::<_, String>(1)?,
            "updated_at": row.get::<_, String>(2)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// chat_messages
// ──────────────────────────────────────────────────────────────────────────────

/// Inserta un mensaje de chat.
///
/// - `role`: "user" | "assistant"
/// - `meta`: JSON opcional, puede ser NULL
///
/// Devuelve rowid (≥1) o 0 en error.
///
/// # Safety
/// Todos los punteros no-meta deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn chat_message_insert(
    handle:     *mut DbHandle,
    session_id: *const c_char,
    timestamp:  *const c_char,
    role:       *const c_char,
    content:    *const c_char,
    meta:       *const c_char,   // puede ser NULL
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let sid = match cstr_to_str(session_id) { Some(s) => s, None => { set_last_error("session_id nulo"); return 0; } };
    let ts  = match cstr_to_str(timestamp)  { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let rl  = match cstr_to_str(role)       { Some(s) => s, None => { set_last_error("role nulo"); return 0; } };
    let cnt = match cstr_to_str(content)    { Some(s) => s, None => { set_last_error("content nulo"); return 0; } };
    let mt: Option<&str> = cstr_to_str(meta);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO chat_messages (session_id, timestamp, role, content, meta) \
         VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![sid, ts, rl, cnt, mt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve el historial de una sesión como JSON array (orden ASC = más antiguo primero).
///
/// JSON por elemento: `{"id":1,"session_id":"...","timestamp":"...","role":"user","content":"...","meta":null}`
///
/// # Safety
/// `handle` y `session_id` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn chat_message_history(
    handle:     *mut DbHandle,
    session_id: *const c_char,
    limit:      i64,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let sid = match cstr_to_str(session_id) {
        Some(s) => s,
        None => { set_last_error("session_id nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 100 } else { limit };
    let conn = h.conn.lock();
    // Subconsulta para tomar los N más recientes y devolver en orden cronológico
    let mut stmt = match conn.prepare(
        "SELECT id, session_id, timestamp, role, content, meta \
         FROM chat_messages WHERE session_id=?1 \
         ORDER BY id DESC LIMIT ?2"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![sid, lim], |row| {
        Ok(serde_json::json!({
            "id":         row.get::<_, i64>(0)?,
            "session_id": row.get::<_, String>(1)?,
            "timestamp":  row.get::<_, String>(2)?,
            "role":       row.get::<_, String>(3)?,
            "content":    row.get::<_, String>(4)?,
            "meta":       row.get::<_, Option<String>>(5)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(mut v) => {
            v.reverse();  // más antiguo primero
            json_to_cstring(&serde_json::Value::Array(v))
        }
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Borra todos los mensajes de una sesión.
/// Devuelve número de filas borradas o -1 en error.
///
/// # Safety
/// `handle` y `session_id` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn chat_session_clear(
    handle:     *mut DbHandle,
    session_id: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let sid = match cstr_to_str(session_id) {
        Some(s) => s,
        None => { set_last_error("session_id nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.execute("DELETE FROM chat_messages WHERE session_id=?1", rusqlite::params![sid]) {
        Ok(n) => n as i64,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

/// Devuelve los últimos `limit` mensajes de TODAS las sesiones (para el endpoint /api/chat/history).
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn chat_message_list_all(
    handle: *mut DbHandle,
    limit:  i64,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 50 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, session_id, timestamp, role, content, meta \
         FROM chat_messages ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":         row.get::<_, i64>(0)?,
            "session_id": row.get::<_, String>(1)?,
            "timestamp":  row.get::<_, String>(2)?,
            "role":       row.get::<_, String>(3)?,
            "content":    row.get::<_, String>(4)?,
            "meta":       row.get::<_, Option<String>>(5)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}
