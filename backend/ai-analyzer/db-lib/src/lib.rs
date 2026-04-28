//! `analyzer-db` — Biblioteca C ABI para SQLite, consumida por Java via Panama FFI.
//!
//! # Uso desde Java (Panama FFI)
//!
//! ```java
//! // 1. Abrir la base de datos
//! MemorySegment handle = DbLibrary.db_open("/data/sensor.db");
//!
//! // 2. Usar funciones de dominio
//! long batchId = DbLibrary.batch_insert(handle, "2025-04-25T12:00:00Z", "192.168.1.50", "{...}");
//!
//! // 3. Leer resultado (JSON string)
//! MemorySegment json = DbLibrary.batch_list_pending(handle, 10);
//! String result = DatabaseClient.readAndFreeRustString(json);
//!
//! // 4. Cerrar al terminar
//! DbLibrary.db_close(handle);
//! ```
//!
//! # Gestión de memoria
//!
//! - Las funciones que devuelven `*mut c_char` transfieren la propiedad a Java.
//!   Java DEBE llamar `db_free_string(ptr)` cuando ya no necesite el valor.
//! - `db_last_error()` devuelve un puntero interno — NO debe liberarse.
//! - `db_close(handle)` libera el handle; no usar después.
//!
//! # Seguridad de hilos
//!
//! El `DbHandle` protege la conexión con `parking_lot::Mutex`.  Es seguro
//! llamar funciones desde múltiples hilos virtuales de Java (Project Loom)
//! con el mismo handle — la concurrencia está serializada dentro de Rust.
//!
//! # Errores
//!
//! Cuando una función falla devuelve 0 / -1 / NULL según su tipo.
//! El mensaje de error está disponible en `db_last_error()` (hilo-local).

#![allow(clippy::missing_safety_doc)]

use std::ffi::CString;
use std::os::raw::c_char;

mod analyses;
mod alerts;
mod batches;
mod chat;
mod domains;
mod error;
mod handle;
mod init;
mod misc;
mod util;

pub use handle::DbHandle;

// ─── db_open ─────────────────────────────────────────────────────────────────

/// Abre (o crea) la base de datos SQLite en `path` y aplica el esquema.
///
/// Devuelve un puntero opaco `*mut DbHandle` que debe pasarse a todas las
/// funciones de este módulo.  Devuelve NULL si falla.
///
/// Java debe cerrar el handle con `db_close` cuando termine.
///
/// # Safety
/// `path` debe ser un puntero C válido (no-nulo, nul-terminado, UTF-8).
#[no_mangle]
pub unsafe extern "C" fn db_open(path: *const c_char) -> *mut DbHandle {
    error::clear_last_error();

    let path_str = match util::cstr_to_str(path) {
        Some(s) => s,
        None => {
            error::set_last_error("path nulo o no es UTF-8 válido");
            return std::ptr::null_mut();
        }
    };

    // Crear directorio padre si no existe
    if let Some(parent) = std::path::Path::new(path_str).parent() {
        if !parent.as_os_str().is_empty() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                error::set_last_error(format!("no se pudo crear directorio {parent:?}: {e}"));
                return std::ptr::null_mut();
            }
        }
    }

    let conn = match rusqlite::Connection::open(path_str) {
        Ok(c) => c,
        Err(e) => {
            error::set_last_error(format!("no se pudo abrir {path_str}: {e}"));
            return std::ptr::null_mut();
        }
    };

    // Aplicar PRAGMA WAL + DDL
    if let Err(e) = init::apply_schema(&conn) {
        error::set_last_error(format!("error aplicando esquema: {e}"));
        return std::ptr::null_mut();
    }

    Box::into_raw(Box::new(DbHandle::new(conn)))
}

// ─── db_ping ─────────────────────────────────────────────────────────────────

/// Comprueba que el handle es válido y la conexión responde.
/// Devuelve 1 si OK, 0 en error.
///
/// # Safety
/// `handle` debe ser un puntero válido obtenido de `db_open`.
#[no_mangle]
pub unsafe extern "C" fn db_ping(handle: *mut DbHandle) -> i64 {
    error::clear_last_error();
    let h = match handle::handle_ref(handle) {
        Some(h) => h,
        None => { error::set_last_error("handle nulo"); return 0; }
    };
    let conn = h.conn.lock();
    match conn.query_row("SELECT 1", [], |r| r.get::<_, i64>(0)) {
        Ok(1) => 1,
        _ => { error::set_last_error("ping falló"); 0 }
    }
}

// ─── db_version ──────────────────────────────────────────────────────────────

/// Devuelve la versión de SQLite como `*mut c_char`.
/// Java debe liberar con `db_free_string`.
#[no_mangle]
pub extern "C" fn db_sqlite_version() -> *mut c_char {
    let ver = rusqlite::version();
    match CString::new(ver) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

// Re-exportar funciones de submodulos públicamente a través de su módulo.
// Los símbolos `#[no_mangle]` ya son visibles en la ABI C al compilar cdylib;
// no hace falta re-exportarlos explícitamente aquí.
