//! CRUD sobre `network_alerts`.

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring},
};

/// Inserta una alerta de red.
///
/// - `severity`: "LOW" | "MEDIUM" | "HIGH" | "CRITICAL"
/// - `alert_type`: etiqueta libre, p.ej. "PORN_BLOCK", "SOCIAL_POLICY"
/// - `source_ip`, `domain`, `meta`: pueden ser NULL
///
/// Devuelve rowid (≥1) o 0 en error.
///
/// # Safety
/// `handle`, `batch_id`, `timestamp`, `severity`, `alert_type`, `message` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn alert_insert(
    handle:     *mut DbHandle,
    batch_id:   i64,
    timestamp:  *const c_char,
    severity:   *const c_char,
    alert_type: *const c_char,
    message:    *const c_char,
    source_ip:  *const c_char,  // puede ser NULL
    domain:     *const c_char,  // puede ser NULL
    meta:       *const c_char,  // puede ser NULL (JSON)
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ts  = match cstr_to_str(timestamp)  { Some(s) => s, None => { set_last_error("timestamp nulo"); return 0; } };
    let sev = match cstr_to_str(severity)   { Some(s) => s, None => { set_last_error("severity nulo"); return 0; } };
    let at  = match cstr_to_str(alert_type) { Some(s) => s, None => { set_last_error("alert_type nulo"); return 0; } };
    let msg = match cstr_to_str(message)    { Some(s) => s, None => { set_last_error("message nulo"); return 0; } };
    let ip: Option<&str>     = cstr_to_str(source_ip);
    let dom: Option<&str>    = cstr_to_str(domain);
    let mt: Option<&str>     = cstr_to_str(meta);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO network_alerts \
         (batch_id, timestamp, severity, alert_type, message, source_ip, domain, meta) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        rusqlite::params![batch_id, ts, sev, at, msg, ip, dom, mt],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve las `limit` alertas más recientes como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn alert_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 50 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, batch_id, timestamp, severity, alert_type, message, source_ip, domain, meta \
         FROM network_alerts ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":         row.get::<_, i64>(0)?,
            "batch_id":   row.get::<_, i64>(1)?,
            "timestamp":  row.get::<_, String>(2)?,
            "severity":   row.get::<_, String>(3)?,
            "alert_type": row.get::<_, String>(4)?,
            "message":    row.get::<_, String>(5)?,
            "source_ip":  row.get::<_, Option<String>>(6)?,
            "domain":     row.get::<_, Option<String>>(7)?,
            "meta":       row.get::<_, Option<String>>(8)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve alertas por severidad como JSON array.
///
/// # Safety
/// `handle` y `severity` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn alert_list_by_severity(
    handle:   *mut DbHandle,
    severity: *const c_char,
    limit:    i64,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let sev = match cstr_to_str(severity) {
        Some(s) => s,
        None => { set_last_error("severity nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 50 } else { limit };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, batch_id, timestamp, severity, alert_type, message, source_ip, domain, meta \
         FROM network_alerts WHERE severity=?1 ORDER BY id DESC LIMIT ?2"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![sev, lim], |row| {
        Ok(serde_json::json!({
            "id":         row.get::<_, i64>(0)?,
            "batch_id":   row.get::<_, i64>(1)?,
            "timestamp":  row.get::<_, String>(2)?,
            "severity":   row.get::<_, String>(3)?,
            "alert_type": row.get::<_, String>(4)?,
            "message":    row.get::<_, String>(5)?,
            "source_ip":  row.get::<_, Option<String>>(6)?,
            "domain":     row.get::<_, Option<String>>(7)?,
            "meta":       row.get::<_, Option<String>>(8)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Cuenta alertas por severidad. Devuelve JSON `{"HIGH":2,"MEDIUM":5,...}` o NULL en error.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn alert_count_by_severity(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT severity, COUNT(*) FROM network_alerts GROUP BY severity"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let pairs: Result<Vec<(String, i64)>, _> = stmt
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))
        .and_then(|m| m.collect());
    drop(stmt);
    drop(conn);

    match pairs {
        Ok(rows) => {
            let mut map = serde_json::Map::new();
            for (k, v) in rows {
                map.insert(k, serde_json::Value::Number(v.into()));
            }
            json_to_cstring(&serde_json::Value::Object(map))
        }
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}
