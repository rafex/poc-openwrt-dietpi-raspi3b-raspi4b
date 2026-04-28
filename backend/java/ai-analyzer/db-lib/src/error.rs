//! Thread-local last-error para comunicar fallos a través del límite FFI.
//!
//! Java llama  `db_last_error()` para obtener un mensaje descriptivo cuando
//! cualquier función devuelve NULL / 0 / -1.

use std::cell::RefCell;
use std::ffi::CString;
use std::os::raw::c_char;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

/// Guarda el mensaje en el slot thread-local.
pub(crate) fn set_last_error(msg: impl Into<Vec<u8>>) {
    let s = CString::new(msg).unwrap_or_else(|_| {
        CString::new("error con bytes nulos").expect("static string")
    });
    LAST_ERROR.with(|cell| *cell.borrow_mut() = Some(s));
}

/// Borra el error guardado (llamar al inicio de cada función pública).
pub(crate) fn clear_last_error() {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = None);
}

/// Devuelve puntero a la cadena de error, o NULL si no hay error.
///
/// # Safety
/// El puntero es válido mientras el hilo viva; Java no debe liberarlo.
/// La vida útil es "hasta la siguiente llamada a cualquier función db_*".
#[no_mangle]
pub extern "C" fn db_last_error() -> *const c_char {
    LAST_ERROR.with(|cell| {
        cell.borrow()
            .as_ref()
            .map_or(std::ptr::null(), |cs| cs.as_ptr())
    })
}

/// Libera una cadena devuelta por Rust (cualquier función que devuelva `*mut c_char`).
///
/// # Safety
/// `ptr` debe haber sido obtenido de una función `db_*` que devuelva `*mut c_char`.
/// Llamar sólo una vez por puntero.
#[no_mangle]
pub unsafe extern "C" fn db_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        // Reconstruir el CString y dejarlo caer, liberando la memoria.
        let _ = std::ffi::CString::from_raw(ptr);
    }
}
