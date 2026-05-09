//! Módulos misceláneos: `policy_actions`, `model_prompt_logs`,
//! `human_explanations`, `network_summaries`, `network_reports`.

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring},
};

// ──────────────────────────────────────────────────────────────────────────────
// policy_actions
// ──────────────────────────────────────────────────────────────────────────────

/// Registra una acción de política (block/unblock/none).
/// `details` puede ser NULL (JSON opcional).
/// Devuelve rowid o 0 en error.
///
/// # Safety
/// `handle`, `timestamp`, `action` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn policy_action_insert(
    handle:    *mut DbHandle,
    timestamp: *const c_char,
    action:    *const c_char,
    reason:    *const c_char,   // puede ser NULL
    details:   *const c_char,  // puede ser NULL (JSON)
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts  = match cstr_to_str(timestamp) { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let act = match cstr_to_str(action)    { Some(s) => s, None => { set_last_error("action nulo"); return 0; } };
    let rsn: Option<&str>  = cstr_to_str(reason);
    let det: Option<&str>  = cstr_to_str(details);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO policy_actions (timestamp, action, reason, details) VALUES (?1,?2,?3,?4)",
        rusqlite::params![ts, act, rsn, det],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve las `limit` acciones de política más recientes como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn policy_action_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 20 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, timestamp, action, reason, details FROM policy_actions ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":        row.get::<_, i64>(0)?,
            "timestamp": row.get::<_, String>(1)?,
            "action":    row.get::<_, String>(2)?,
            "reason":    row.get::<_, Option<String>>(3)?,
            "details":   row.get::<_, Option<String>>(4)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// model_prompt_logs
// ──────────────────────────────────────────────────────────────────────────────

/// Registra un prompt+respuesta de modelo LLM.
/// `batch_id` = 0 si no aplica. `response` y `meta` pueden ser NULL.
/// Devuelve rowid o 0 en error.
///
/// # Safety
/// `handle`, `timestamp`, `prompt_type`, `prompt` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn prompt_log_insert(
    handle:      *mut DbHandle,
    timestamp:   *const c_char,
    batch_id:    i64,            // 0 = sin batch
    prompt_type: *const c_char,
    prompt:      *const c_char,
    response:    *const c_char,  // puede ser NULL
    meta:        *const c_char,  // puede ser NULL (JSON)
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts  = match cstr_to_str(timestamp)   { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let pt  = match cstr_to_str(prompt_type) { Some(s) => s, None => { set_last_error("prompt_type nulo"); return 0; } };
    let prm = match cstr_to_str(prompt)      { Some(s) => s, None => { set_last_error("prompt nulo"); return 0; } };
    let rsp: Option<&str> = cstr_to_str(response);
    let mt: Option<&str>  = cstr_to_str(meta);
    let bid: Option<i64>  = if batch_id == 0 { None } else { Some(batch_id) };

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO model_prompt_logs (timestamp, batch_id, prompt_type, prompt, response, meta) \
         VALUES (?1,?2,?3,?4,?5,?6)",
        rusqlite::params![ts, bid, pt, prm, rsp, mt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// human_explanations
// ──────────────────────────────────────────────────────────────────────────────

/// Inserta una explicación en lenguaje natural para un batch.
/// `meta` puede ser NULL.
/// Devuelve rowid o 0 en error.
///
/// # Safety
/// `handle`, `batch_id`, `timestamp`, `text` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn human_explanation_insert(
    handle:    *mut DbHandle,
    batch_id:  i64,
    timestamp: *const c_char,
    text:      *const c_char,
    meta:      *const c_char,  // puede ser NULL
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts  = match cstr_to_str(timestamp) { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let txt = match cstr_to_str(text)      { Some(s) => s, None => { set_last_error("text nulo"); return 0; } };
    let mt: Option<&str> = cstr_to_str(meta);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO human_explanations (batch_id, timestamp, text, meta) VALUES (?1,?2,?3,?4)",
        rusqlite::params![batch_id, ts, txt, mt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve la última explicación de un batch como JSON o NULL si no existe.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn human_explanation_get_by_batch(
    handle:   *mut DbHandle,
    batch_id: i64,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let res = conn.query_row(
        "SELECT id, batch_id, timestamp, text, meta FROM human_explanations \
         WHERE batch_id=?1 ORDER BY id DESC LIMIT 1",
        rusqlite::params![batch_id],
        |row| {
            Ok(serde_json::json!({
                "id":        row.get::<_, i64>(0)?,
                "batch_id":  row.get::<_, i64>(1)?,
                "timestamp": row.get::<_, String>(2)?,
                "text":      row.get::<_, String>(3)?,
                "meta":      row.get::<_, Option<String>>(4)?,
            }))
        },
    );
    match res {
        Ok(v) => json_to_cstring(&v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// network_summaries
// ──────────────────────────────────────────────────────────────────────────────

/// Inserta un resumen periódico de red. `meta` puede ser NULL.
/// Devuelve rowid o 0 en error.
///
/// # Safety
/// `handle`, `timestamp`, `summary` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn summary_insert(
    handle:    *mut DbHandle,
    timestamp: *const c_char,
    summary:   *const c_char,
    meta:      *const c_char,  // puede ser NULL
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts  = match cstr_to_str(timestamp) { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let sum = match cstr_to_str(summary)   { Some(s) => s, None => { set_last_error("summary nulo"); return 0; } };
    let mt: Option<&str> = cstr_to_str(meta);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO network_summaries (timestamp, summary, meta) VALUES (?1,?2,?3)",
        rusqlite::params![ts, sum, mt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve los `limit` resúmenes más recientes como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn summary_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 10 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, timestamp, summary, meta FROM network_summaries ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":        row.get::<_, i64>(0)?,
            "timestamp": row.get::<_, String>(1)?,
            "summary":   row.get::<_, String>(2)?,
            "meta":      row.get::<_, Option<String>>(3)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// network_reports
// ──────────────────────────────────────────────────────────────────────────────

/// Inserta un reporte de red. `meta` puede ser NULL.
/// Devuelve rowid o 0 en error.
///
/// # Safety
/// `handle`, `timestamp`, `report` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn report_insert(
    handle:    *mut DbHandle,
    timestamp: *const c_char,
    report:    *const c_char,
    meta:      *const c_char,  // puede ser NULL
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts  = match cstr_to_str(timestamp) { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let rpt = match cstr_to_str(report)    { Some(s) => s, None => { set_last_error("report nulo"); return 0; } };
    let mt: Option<&str> = cstr_to_str(meta);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO network_reports (timestamp, report, meta) VALUES (?1,?2,?3)",
        rusqlite::params![ts, rpt, mt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve los `limit` reportes más recientes como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn report_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 10 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, timestamp, report, meta FROM network_reports ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":        row.get::<_, i64>(0)?,
            "timestamp": row.get::<_, String>(1)?,
            "report":    row.get::<_, String>(2)?,
            "meta":      row.get::<_, Option<String>>(3)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}
