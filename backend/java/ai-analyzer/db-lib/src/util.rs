//! Utilidades internas: conversión de cadenas C↔Rust y serialización JSON.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Convierte `*const c_char` en `&str`.  Devuelve `None` si el puntero es
/// nulo o contiene bytes UTF-8 inválidos.
///
/// # Safety
/// `ptr` debe ser no-nulo, nul-terminado y válido durante la llamada.
pub(crate) unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

/// Serializa `value` como JSON y devuelve un `*mut c_char` que Java debe
/// liberar con `db_free_string`.  Devuelve NULL si la serialización falla.
pub(crate) fn json_to_cstring(value: &serde_json::Value) -> *mut c_char {
    match serde_json::to_string(value) {
        Ok(s) => string_to_raw(s),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Convierte un `String` en `*mut c_char` (Java libera con `db_free_string`).
pub(crate) fn string_to_raw(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Convierte un `i64` resultado de un INSERT en un valor de retorno para FFI.
/// Devuelve el rowid (≥1) o 0 en caso de error.
#[allow(dead_code)]
pub(crate) fn rowid_or_zero(r: rusqlite::Result<i64>) -> i64 {
    r.unwrap_or(0)
}
