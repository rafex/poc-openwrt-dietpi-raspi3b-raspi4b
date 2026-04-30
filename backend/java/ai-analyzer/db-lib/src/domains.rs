//! CRUD sobre `domain_categories`, `domain_whitelist` y `device_profiles`.

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring},
};

// ──────────────────────────────────────────────────────────────────────────────
// domain_categories
// ──────────────────────────────────────────────────────────────────────────────

/// Inserta o actualiza la categoría de un dominio.
///
/// - `category`: "social", "porn", "news", "adult", "search", "cdn", …
/// - `confidence`: 0.0–1.0
/// - `source`: "rule" | "llm" | "manual"
///
/// Devuelve 1 en éxito, 0 en error.
///
/// # Safety
/// Todos los punteros deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn domain_category_upsert(
    handle:     *mut DbHandle,
    domain:     *const c_char,
    category:   *const c_char,
    confidence: f64,
    source:     *const c_char,
    updated_at: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let dom = match cstr_to_str(domain)     { Some(s) => s, None => { set_last_error("domain nulo"); return 0; } };
    let cat = match cstr_to_str(category)   { Some(s) => s, None => { set_last_error("category nulo"); return 0; } };
    let src = cstr_to_str(source).unwrap_or("rule");
    let ua  = match cstr_to_str(updated_at) { Some(s) => s, None => { set_last_error("updated_at nulo"); return 0; } };

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO domain_categories (domain, category, confidence, source, updated_at) \
         VALUES (?1,?2,?3,?4,?5) \
         ON CONFLICT(domain) DO UPDATE SET \
           category=excluded.category, confidence=excluded.confidence, \
           source=excluded.source, updated_at=excluded.updated_at",
        rusqlite::params![dom, cat, confidence, src, ua],
    ) {
        Ok(_) => 1,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve la categoría del dominio como JSON, o NULL si no existe.
///
/// # Safety
/// `handle` y `domain` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn domain_category_get(
    handle: *mut DbHandle,
    domain: *const c_char,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let dom = match cstr_to_str(domain) {
        Some(s) => s,
        None => { set_last_error("domain nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let res = conn.query_row(
        "SELECT domain, category, confidence, source, updated_at \
         FROM domain_categories WHERE domain=?1",
        rusqlite::params![dom],
        |row| {
            Ok(serde_json::json!({
                "domain":     row.get::<_, String>(0)?,
                "category":   row.get::<_, String>(1)?,
                "confidence": row.get::<_, f64>(2)?,
                "source":     row.get::<_, String>(3)?,
                "updated_at": row.get::<_, String>(4)?,
            }))
        },
    );
    match res {
        Ok(v) => json_to_cstring(&v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve todas las categorías como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn domain_category_list(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT domain, category, confidence, source, updated_at \
         FROM domain_categories ORDER BY domain"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map([], |row| {
        Ok(serde_json::json!({
            "domain":     row.get::<_, String>(0)?,
            "category":   row.get::<_, String>(1)?,
            "confidence": row.get::<_, f64>(2)?,
            "source":     row.get::<_, String>(3)?,
            "updated_at": row.get::<_, String>(4)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// domain_whitelist
// ──────────────────────────────────────────────────────────────────────────────

/// Agrega un dominio a la whitelist. `reason` puede ser NULL.
/// Devuelve 1 en éxito, 0 en error.
///
/// # Safety
/// `handle`, `domain` y `created_at` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn whitelist_add(
    handle:     *mut DbHandle,
    domain:     *const c_char,
    reason:     *const c_char,   // puede ser NULL
    created_at: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let dom = match cstr_to_str(domain)     { Some(s) => s, None => { set_last_error("domain nulo"); return 0; } };
    let ca  = match cstr_to_str(created_at) { Some(s) => s, None => { set_last_error("created_at nulo"); return 0; } };
    let rsn: Option<&str> = cstr_to_str(reason);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT OR IGNORE INTO domain_whitelist (domain, reason, created_at) VALUES (?1,?2,?3)",
        rusqlite::params![dom, rsn, ca],
    ) {
        Ok(_) => 1,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Comprueba si un dominio está en la whitelist. Devuelve 1 si está, 0 si no, -1 en error.
///
/// # Safety
/// `handle` y `domain` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn whitelist_contains(
    handle: *mut DbHandle,
    domain: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let dom = match cstr_to_str(domain) {
        Some(s) => s,
        None => { set_last_error("domain nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.query_row(
        "SELECT COUNT(*) FROM domain_whitelist WHERE domain=?1",
        rusqlite::params![dom],
        |r| r.get::<_, i64>(0),
    ) {
        Ok(n) => if n > 0 { 1 } else { 0 },
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

/// Devuelve todos los dominios en whitelist como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn whitelist_list(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT domain, reason, created_at FROM domain_whitelist ORDER BY domain"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map([], |row| {
        Ok(serde_json::json!({
            "domain":     row.get::<_, String>(0)?,
            "reason":     row.get::<_, Option<String>>(1)?,
            "created_at": row.get::<_, String>(2)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Elimina un dominio de la whitelist. Devuelve 1 si existía, 0 si no, -1 en error.
///
/// # Safety
/// `handle` y `domain` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn whitelist_remove(
    handle: *mut DbHandle,
    domain: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return -1; }
    };
    let dom = match cstr_to_str(domain) {
        Some(s) => s,
        None => { set_last_error("domain nulo"); return -1; }
    };
    let conn = h.conn.lock();
    match conn.execute("DELETE FROM domain_whitelist WHERE domain=?1", rusqlite::params![dom]) {
        Ok(n) => n as i64,
        Err(e) => { set_last_error(e.to_string()); -1 }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// device_profiles
// ──────────────────────────────────────────────────────────────────────────────

/// Inserta o actualiza el perfil de un dispositivo por IP.
///
/// - `device_type`: "phone", "laptop", "iot", "tv", …
/// - `reasons`: JSON string (array) o NULL
///
/// Devuelve 1 en éxito, 0 en error.
///
/// # Safety
/// Todos los punteros deben ser válidos excepto `reasons`.
#[no_mangle]
pub unsafe extern "C" fn device_profile_upsert(
    handle:      *mut DbHandle,
    ip:          *const c_char,
    device_type: *const c_char,
    confidence:  f64,
    reasons:     *const c_char,  // puede ser NULL
    updated_at:  *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let ip_s = match cstr_to_str(ip)          { Some(s) => s, None => { set_last_error("ip nulo"); return 0; } };
    let dt   = match cstr_to_str(device_type) { Some(s) => s, None => { set_last_error("device_type nulo"); return 0; } };
    let ua   = match cstr_to_str(updated_at)  { Some(s) => s, None => { set_last_error("updated_at nulo"); return 0; } };
    let rsn: Option<&str> = cstr_to_str(reasons);

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT INTO device_profiles (ip, device_type, confidence, reasons, updated_at) \
         VALUES (?1,?2,?3,?4,?5) \
         ON CONFLICT(ip) DO UPDATE SET \
           device_type=excluded.device_type, confidence=excluded.confidence, \
           reasons=excluded.reasons, updated_at=excluded.updated_at",
        rusqlite::params![ip_s, dt, confidence, rsn, ua],
    ) {
        Ok(_) => 1,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve el perfil de un dispositivo por IP como JSON, o NULL si no existe.
///
/// # Safety
/// `handle` y `ip` deben ser punteros válidos.
#[no_mangle]
pub unsafe extern "C" fn device_profile_get(
    handle: *mut DbHandle,
    ip:     *const c_char,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let ip_s = match cstr_to_str(ip) {
        Some(s) => s,
        None => { set_last_error("ip nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let res = conn.query_row(
        "SELECT ip, device_type, confidence, reasons, updated_at \
         FROM device_profiles WHERE ip=?1",
        rusqlite::params![ip_s],
        |row| {
            Ok(serde_json::json!({
                "ip":          row.get::<_, String>(0)?,
                "device_type": row.get::<_, String>(1)?,
                "confidence":  row.get::<_, f64>(2)?,
                "reasons":     row.get::<_, Option<String>>(3)?,
                "updated_at":  row.get::<_, String>(4)?,
            }))
        },
    );
    match res {
        Ok(v) => json_to_cstring(&v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve todos los perfiles de dispositivos como JSON array.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn device_profile_list(handle: *mut DbHandle) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();
    let mut stmt = match conn.prepare(
        "SELECT ip, device_type, confidence, reasons, updated_at \
         FROM device_profiles ORDER BY updated_at DESC"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map([], |row| {
        Ok(serde_json::json!({
            "ip":          row.get::<_, String>(0)?,
            "device_type": row.get::<_, String>(1)?,
            "confidence":  row.get::<_, f64>(2)?,
            "reasons":     row.get::<_, Option<String>>(3)?,
            "updated_at":  row.get::<_, String>(4)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}
