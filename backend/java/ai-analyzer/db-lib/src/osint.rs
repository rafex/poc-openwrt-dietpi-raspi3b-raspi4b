//! CRUD sobre `osint_enrichments`.
//!
//! Almacena el resultado del pipeline OSINT:
//!   PHOMBER (tablas ASCII) + Bing dorks (snippets) → LLM (JSON estructurado)
//!
//! El campo `source` distingue la fuente: phomber-ip | phomber-dns |
//! phomber-whois | phomber-mac | bing-dork.
//! El campo `expires_at` implementa la caché TTL — la consulta `osint_is_cached`
//! compara con el timestamp actual para decidir si re-enriquecer.

use std::os::raw::c_char;

use crate::{
    error::{clear_last_error, set_last_error},
    handle::{handle_ref, DbHandle},
    util::{cstr_to_str, json_to_cstring},
};

/// Inserta o reemplaza un enriquecimiento OSINT (UPSERT por target+target_type+source).
///
/// - `alert_id`:    -1 si no aplica
/// - `batch_id`:    -1 si no aplica
/// - `phomber_raw`: puede ser NULL — stdout de PHOMBER sin ANSI
/// - `bing_raw`:    puede ser NULL — JSON de snippets Bing
/// - `llm_result`:  puede ser NULL — JSON extraído por el LLM
/// - `risk`:        puede ser NULL
/// - `summary_es`:  puede ser NULL
///
/// Devuelve rowid (≥1) o 0 en error.
///
/// # Safety
/// `handle`, `target`, `target_type`, `source`, `queried_at`, `expires_at` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn osint_insert(
    handle:      *mut DbHandle,
    alert_id:    i64,
    batch_id:    i64,
    target:      *const c_char,
    target_type: *const c_char,
    source:      *const c_char,
    phomber_raw: *const c_char,
    bing_raw:    *const c_char,
    llm_result:  *const c_char,
    risk:        *const c_char,
    summary_es:  *const c_char,
    queried_at:  *const c_char,
    expires_at:  *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };

    let tgt  = match cstr_to_str(target)      { Some(s) => s, None => { set_last_error("target nulo"); return 0; } };
    let ttyp = match cstr_to_str(target_type) { Some(s) => s, None => { set_last_error("target_type nulo"); return 0; } };
    let src  = match cstr_to_str(source)      { Some(s) => s, None => { set_last_error("source nulo"); return 0; } };
    let qat  = match cstr_to_str(queried_at)  { Some(s) => s, None => { set_last_error("queried_at nulo"); return 0; } };
    let eat  = match cstr_to_str(expires_at)  { Some(s) => s, None => { set_last_error("expires_at nulo"); return 0; } };

    let phomber: Option<&str> = cstr_to_str(phomber_raw);
    let bing:    Option<&str> = cstr_to_str(bing_raw);
    let llm:     Option<&str> = cstr_to_str(llm_result);
    let rsk:     Option<&str> = cstr_to_str(risk);
    let sum:     Option<&str> = cstr_to_str(summary_es);

    // alert_id / batch_id: -1 significa NULL
    let aid: Option<i64> = if alert_id < 0 { None } else { Some(alert_id) };
    let bid: Option<i64> = if batch_id < 0 { None } else { Some(batch_id) };

    let conn = h.conn.lock();
    match conn.execute(
        "INSERT OR REPLACE INTO osint_enrichments \
         (alert_id, batch_id, target, target_type, source, \
          phomber_raw, bing_raw, llm_result, risk, summary_es, \
          queried_at, expires_at) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
        rusqlite::params![aid, bid, tgt, ttyp, src, phomber, bing, llm, rsk, sum, qat, eat],
    ) {
        Ok(_) => conn.last_insert_rowid(),
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Comprueba si existe un enriquecimiento vigente (sin expirar) para target+source.
///
/// - `now_iso`: timestamp actual en ISO 8601 UTC — se compara con expires_at
///
/// Devuelve 1 si está en caché, 0 si no (o en error).
///
/// # Safety
/// `handle`, `target`, `source`, `now_iso` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn osint_is_cached(
    handle:  *mut DbHandle,
    target:  *const c_char,
    source:  *const c_char,
    now_iso: *const c_char,
) -> i64 {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return 0; }
    };
    let tgt = match cstr_to_str(target)  { Some(s) => s, None => return 0 };
    let src = match cstr_to_str(source)  { Some(s) => s, None => return 0 };
    let now = match cstr_to_str(now_iso) { Some(s) => s, None => return 0 };

    let conn = h.conn.lock();
    match conn.query_row(
        "SELECT 1 FROM osint_enrichments \
         WHERE target=?1 AND source=?2 AND expires_at > ?3 LIMIT 1",
        rusqlite::params![tgt, src, now],
        |_| Ok(1_i64),
    ) {
        Ok(v) => v,
        Err(rusqlite::Error::QueryReturnedNoRows) => 0,
        Err(e) => { set_last_error(e.to_string()); 0 }
    }
}

/// Devuelve los `limit` enriquecimientos más recientes como JSON array.
/// Los campos voluminosos (phomber_raw, bing_raw, llm_result) se omiten.
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn osint_list_recent(handle: *mut DbHandle, limit: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let lim = if limit <= 0 { 50 } else { limit };
    let conn = h.conn.lock();

    let mut stmt = match conn.prepare(
        "SELECT id, alert_id, batch_id, target, target_type, source, \
                risk, summary_es, queried_at, expires_at \
         FROM osint_enrichments ORDER BY id DESC LIMIT ?1"
    ) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    let rows: Result<Vec<_>, _> = stmt.query_map(rusqlite::params![lim], |row| {
        Ok(serde_json::json!({
            "id":          row.get::<_, i64>(0)?,
            "alert_id":    row.get::<_, Option<i64>>(1)?,
            "batch_id":    row.get::<_, Option<i64>>(2)?,
            "target":      row.get::<_, String>(3)?,
            "target_type": row.get::<_, String>(4)?,
            "source":      row.get::<_, String>(5)?,
            "risk":        row.get::<_, Option<String>>(6)?,
            "summary_es":  row.get::<_, Option<String>>(7)?,
            "queried_at":  row.get::<_, String>(8)?,
            "expires_at":  row.get::<_, String>(9)?,
        }))
    }).and_then(|m| m.collect());

    match rows {
        Ok(v) => json_to_cstring(&serde_json::Value::Array(v)),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve el detalle completo de un enriquecimiento por ID (incluye campos raw).
///
/// # Safety
/// `handle` debe ser un puntero válido.
#[no_mangle]
pub unsafe extern "C" fn osint_get_detail(handle: *mut DbHandle, id: i64) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let conn = h.conn.lock();

    let result = conn.query_row(
        "SELECT id, alert_id, batch_id, target, target_type, source, \
                phomber_raw, bing_raw, llm_result, risk, summary_es, \
                queried_at, expires_at \
         FROM osint_enrichments WHERE id=?1",
        rusqlite::params![id],
        |row| {
            Ok(serde_json::json!({
                "id":          row.get::<_, i64>(0)?,
                "alert_id":    row.get::<_, Option<i64>>(1)?,
                "batch_id":    row.get::<_, Option<i64>>(2)?,
                "target":      row.get::<_, String>(3)?,
                "target_type": row.get::<_, String>(4)?,
                "source":      row.get::<_, String>(5)?,
                "phomber_raw": row.get::<_, Option<String>>(6)?,
                "bing_raw":    row.get::<_, Option<String>>(7)?,
                "llm_result":  row.get::<_, Option<String>>(8)?,
                "risk":        row.get::<_, Option<String>>(9)?,
                "summary_es":  row.get::<_, Option<String>>(10)?,
                "queried_at":  row.get::<_, String>(11)?,
                "expires_at":  row.get::<_, String>(12)?,
            }))
        },
    );

    match result {
        Ok(v) => json_to_cstring(&v),
        Err(rusqlite::Error::QueryReturnedNoRows) => std::ptr::null_mut(),
        Err(e) => { set_last_error(e.to_string()); std::ptr::null_mut() }
    }
}

/// Devuelve alertas HIGH/CRITICAL sin enriquecimiento OSINT vigente.
/// Usada por OsintOrchestrator para encontrar trabajo pendiente.
///
/// - `min_severity`: "HIGH" | "CRITICAL"
/// - `now_iso`:      timestamp actual
///
/// # Safety
/// `handle`, `min_severity`, `now_iso` deben ser válidos.
#[no_mangle]
pub unsafe extern "C" fn osint_pending_alerts(
    handle:       *mut DbHandle,
    min_severity: *const c_char,
    now_iso:      *const c_char,
    limit:        i64,
) -> *mut c_char {
    clear_last_error();
    let h = match handle_ref(handle) {
        Some(h) => h,
        None => { set_last_error("handle nulo"); return std::ptr::null_mut(); }
    };
    let sev = cstr_to_str(min_severity).unwrap_or("HIGH");
    let now = match cstr_to_str(now_iso)      { Some(s) => s, None => { set_last_error("now_iso nulo"); return std::ptr::null_mut(); } };
    let lim = if limit <= 0 { 20 } else { limit };

    // Determinar severidades >= min
    let severities: Vec<&str> = match sev.to_uppercase().as_str() {
        "CRITICAL" => vec!["CRITICAL"],
        _          => vec!["HIGH", "CRITICAL"],
    };

    let conn = h.conn.lock();

    // Construir query con IN clause dinámico
    let placeholders: Vec<String> = (1..=severities.len()).map(|i| format!("?{}", i)).collect();
    let in_clause = placeholders.join(",");
    let now_idx   = severities.len() + 1;
    let lim_idx   = severities.len() + 2;

    let sql = format!(
        "SELECT a.id, a.batch_id, a.timestamp, a.severity, a.alert_type, \
                a.message, a.source_ip, a.domain, a.meta \
         FROM network_alerts a \
         WHERE a.severity IN ({in_clause}) \
           AND NOT EXISTS ( \
               SELECT 1 FROM osint_enrichments e \
               WHERE e.alert_id = a.id AND e.expires_at > ?{now_idx} \
           ) \
         ORDER BY a.id DESC LIMIT ?{lim_idx}"
    );

    let mut stmt = match conn.prepare(&sql) {
        Ok(s) => s,
        Err(e) => { set_last_error(e.to_string()); return std::ptr::null_mut(); }
    };

    // Construir parámetros dinámicamente
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = severities
        .iter()
        .map(|s| Box::new(s.to_string()) as Box<dyn rusqlite::ToSql>)
        .collect();
    params.push(Box::new(now.to_string()));
    params.push(Box::new(lim));

    let params_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    let rows: Result<Vec<_>, _> = stmt.query_map(params_refs.as_slice(), |row| {
        Ok(serde_json::json!({
            "id":         row.get::<_, i64>(0)?,
            "batch_id":   row.get::<_, Option<i64>>(1)?,
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
