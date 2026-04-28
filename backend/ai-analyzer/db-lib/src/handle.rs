//! `DbHandle` — wrapper opaco sobre una conexión SQLite protegida por Mutex.
//!
//! Java recibe un `*mut DbHandle` (puntero opaco) y lo pasa de vuelta en cada
//! llamada.  El Arc interior permite clonar el handle para futuros usos en
//! hilos virtuales (Project Loom) sin necesidad de un pool externo.

use std::sync::Arc;

use parking_lot::Mutex;
use rusqlite::Connection;

/// Handle opaco que envuelve la conexión SQLite.
/// Se crea en el heap con `Box::new` y se devuelve como `*mut DbHandle`.
pub struct DbHandle {
    pub(crate) conn: Arc<Mutex<Connection>>,
}

impl DbHandle {
    pub fn new(conn: Connection) -> Self {
        Self {
            conn: Arc::new(Mutex::new(conn)),
        }
    }

    /// Clona el Arc interno — útil para operaciones concurrentes.
    #[allow(dead_code)]
    pub(crate) fn clone_arc(&self) -> Arc<Mutex<Connection>> {
        Arc::clone(&self.conn)
    }
}

/// Convierte el puntero raw (venido de Java) de vuelta a una referencia segura.
///
/// # Safety
/// `ptr` debe ser no-nulo, alineado y apuntar a un `DbHandle` vivo.
/// Java obtiene este puntero de `db_open` y lo gestiona con `db_close`.
pub(crate) unsafe fn handle_ref<'a>(ptr: *mut DbHandle) -> Option<&'a DbHandle> {
    if ptr.is_null() {
        None
    } else {
        Some(&*ptr)
    }
}

/// Cierra el handle (libera la conexión y el Box).
///
/// # Safety
/// Igual que `handle_ref`.  No debe usarse `ptr` después de esta llamada.
#[no_mangle]
pub unsafe extern "C" fn db_close(ptr: *mut DbHandle) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr); // droppea el Box → Arc → Connection
    }
}
