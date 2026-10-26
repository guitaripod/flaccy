//! Who a REST call acts as: the security-store user behind the login and the
//! synthesized device it writes from.

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, MutexGuard};

use crate::auth::Login;
use crate::error::ApiError;
use crate::security::rest::KeyHolder;
use crate::security::{DeviceId, KeyId, Principal, Role, SecurityError, UserId};
use crate::state::{adopt_legacy_account, AppState};

const DEVICE_PREFIX: &str = "opensubsonic:";
const PASSWORD_DEVICE: &str = "password";

/// The credential a request presented as `apiKey` that the security store recognised.
pub(crate) enum Presented {
    /// An OpenSubsonic API key and its owner.
    Key(KeyHolder),
    /// The token of an enrolled Flaccy device, which works as an API key for the app that holds it.
    Device {
        /// The device's user, role and id.
        principal: Principal,
        /// The user's display name.
        user_name: String,
        /// The device's name.
        device_name: String,
    },
}

impl Presented {
    /// The name of the key or device, for the login.
    pub(crate) fn name(&self) -> &str {
        match self {
            Presented::Key(holder) => &holder.name,
            Presented::Device { device_name, .. } => device_name,
        }
    }
}

/// A resolved login.
pub(crate) struct Identity {
    /// The user, their role and the device the call writes as.
    pub principal: Principal,
    /// The user's display name.
    pub username: String,
}

/// What the REST calls remember about identities so a call asks the security store as little as it can: the
/// synthesized devices already written, and which keys were copied from `credentials.toml`.
#[derive(Default)]
pub struct RestIdentities {
    devices: Mutex<HashSet<String>>,
    imported: Mutex<HashMap<String, bool>>,
}

impl RestIdentities {
    fn devices(&self) -> MutexGuard<'_, HashSet<String>> {
        self.devices.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn imported(&self) -> MutexGuard<'_, HashMap<String, bool>> {
        self.imported.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn storage_failure(error: SecurityError) -> ApiError {
    ApiError::generic(format!(
        "Could not look up who this login belongs to: {error} Check that the data folder is writable and the disk is not full, then try again."
    ))
}

fn unknown_key() -> ApiError {
    ApiError::new(
        44,
        "The API key is not known to this server; it may have been revoked. Make a new one with `flaccy-server key add <name>` and enter it in your client.",
    )
}

/// Code 50: the user may not do what the call asks.
pub(crate) fn not_authorized(what: &str) -> ApiError {
    ApiError::new(
        50,
        format!("This user may not {what}. Ask the server's admin for the member role (`flaccy-server user role <name> member`), then try again."),
    )
}

async fn device_for(state: &AppState, id: &str, user: &UserId, name: &str) -> Result<DeviceId, ApiError> {
    if !state.0.rest_identities.devices().contains(id) {
        state.0.security.ensure_rest_device(id, user, name).await.map_err(storage_failure)?;
        state.0.rest_identities.devices().insert(id.to_owned());
    }
    Ok(DeviceId(id.to_owned()))
}

async fn imported_from_credentials(state: &AppState, key: &KeyId) -> Result<bool, ApiError> {
    if let Some(known) = state.0.rest_identities.imported().get(key.as_str()) {
        return Ok(*known);
    }
    let imported = state.0.security.was_imported(key).await.map_err(storage_failure)?;
    state.0.rest_identities.imported().insert(key.to_string(), imported);
    Ok(imported)
}

async fn device_credential(state: &AppState, secret: &str) -> Result<Option<Presented>, ApiError> {
    let security = &state.0.security;
    let Some(principal) = security.authenticate(secret).await.map_err(storage_failure)? else {
        return Ok(None);
    };
    let Some(device) = &principal.device else {
        return Ok(None);
    };
    let device_name = security
        .list_devices(Some(&principal.user))
        .await
        .map_err(storage_failure)?
        .into_iter()
        .find(|known| known.id == *device)
        .map(|known| known.name)
        .unwrap_or_default();
    let user = security.get_user(&principal.user).await.map_err(storage_failure)?;
    Ok(user.map(|user| Presented::Device {
        principal,
        user_name: user.name,
        device_name,
    }))
}

/// What the security store makes of the `apiKey` a request presents, `None` when it presents none or one nobody holds.
///
/// A key `credentials.toml` lists is copied into the security store on first use. A key the store holds that came
/// from `credentials.toml` and is no longer listed there was revoked with `flaccy-server key revoke`, and stays
/// refused. A value that is no key at all may be the token of an enrolled device.
pub(crate) async fn key_holder(state: &AppState, secret: Option<&str>) -> Result<Option<Presented>, ApiError> {
    let Some(secret) = secret else {
        return Ok(None);
    };
    let security = &state.0.security;
    let account = state.credentials();
    let listed = account.as_ref().is_some_and(|account| account.key_name(secret).is_some());
    let mut holder = security.find_api_key(secret).await.map_err(storage_failure)?;
    if holder.is_none() && listed {
        if let Some(account) = &account {
            adopt_legacy_account(security, account).await.map_err(ApiError::generic)?;
        }
        holder = security.find_api_key(secret).await.map_err(storage_failure)?;
    }
    match holder {
        Some(found) if !listed && imported_from_credentials(state, &found.key).await? => Ok(None),
        Some(found) => Ok(Some(Presented::Key(found))),
        None => device_credential(state, secret).await,
    }
}

async fn key_identity(state: &AppState, holder: KeyHolder) -> Result<Identity, ApiError> {
    let device = device_for(state, holder.key.as_str(), &holder.user, &format!("{DEVICE_PREFIX}{}", holder.name)).await?;
    Ok(Identity {
        principal: Principal {
            user: holder.user,
            role: holder.role,
            device: Some(device),
        },
        username: holder.user_name,
    })
}

async fn account_identity(state: &AppState) -> Result<Identity, ApiError> {
    let security = &state.0.security;
    let owner = match security.owner().await.map_err(storage_failure)? {
        Some(owner) => owner,
        None => {
            let account = state.credentials().ok_or_else(unknown_key)?;
            security.ensure_owner(&account.username).await.map_err(storage_failure)?
        }
    };
    let device = device_for(state, &format!("pw-{}", owner.id), &owner.id, &format!("{DEVICE_PREFIX}{PASSWORD_DEVICE}")).await?;
    Ok(Identity {
        principal: Principal {
            user: owner.id,
            role: owner.role,
            device: Some(device),
        },
        username: owner.name,
    })
}

/// The identity a verified login acts as. A pending user may do nothing and is refused.
pub(crate) async fn resolve(state: &AppState, login: &Login, presented: Option<Presented>) -> Result<Identity, ApiError> {
    let identity = match (login, presented) {
        (Login::Key(_), Some(Presented::Key(holder))) => key_identity(state, holder).await?,
        (Login::Key(_), Some(Presented::Device { principal, user_name, .. })) => Identity {
            principal,
            username: user_name,
        },
        (Login::Key(_), None) => return Err(unknown_key()),
        (Login::Account, _) => account_identity(state).await?,
    };
    if identity.principal.role == Role::Pending {
        return Err(not_authorized("use the library until it has been approved"));
    }
    Ok(identity)
}
