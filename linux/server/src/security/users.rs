//! People who may use the server, and what each may do.

use rusqlite::types::{FromSql, FromSqlError, FromSqlResult, ToSql, ToSqlOutput, ValueRef};
use rusqlite::{Connection, OptionalExtension, Row};

use super::keys::random_uuid;
use super::{clean_name, SecurityError, Stamp, Store, UserId};

/// What a user may do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// Manages users, devices and settings.
    Admin,
    /// Uses the library and keeps their own playlists and listens.
    Member,
    /// Listens without keeping anything of their own.
    Guest,
    /// Known but not yet approved; may do nothing.
    Pending,
}

impl Role {
    /// The word stored in the database and sent over the API.
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Member => "member",
            Role::Guest => "guest",
            Role::Pending => "pending",
        }
    }

    /// The role a word names, `None` for anything else.
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "admin" => Some(Role::Admin),
            "member" => Some(Role::Member),
            "guest" => Some(Role::Guest),
            "pending" => Some(Role::Pending),
            _ => None,
        }
    }
}

impl FromSql for Role {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        let word = value.as_str()?;
        Role::parse(word).ok_or_else(|| FromSqlError::Other("the users table holds a role this build does not know".into()))
    }
}

impl ToSql for Role {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        self.as_str().to_sql()
    }
}

/// One user as stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct User {
    /// The user's id.
    pub id: UserId,
    /// The display name, unique ignoring case.
    pub name: String,
    /// The Tailscale user id, once household mode has linked one.
    pub tailnet_user_id: Option<String>,
    /// The Tailscale login name, once linked.
    pub login: Option<String>,
    /// What the user may do.
    pub role: Role,
    /// When the user was made, in Unix milliseconds.
    pub created_at: i64,
}

const USER_COLUMNS: &str = "id, name, tailnet_user_id, login, role, created_at";

fn user_from_row(row: &Row<'_>) -> rusqlite::Result<User> {
    Ok(User {
        id: row.get(0)?,
        name: row.get(1)?,
        tailnet_user_id: row.get(2)?,
        login: row.get(3)?,
        role: row.get(4)?,
        created_at: row.get(5)?,
    })
}

pub(super) fn require_user(connection: &Connection, id: &UserId) -> Result<User, SecurityError> {
    connection
        .query_row(&format!("SELECT {USER_COLUMNS} FROM users WHERE id = ?1"), [id], user_from_row)
        .optional()?
        .ok_or_else(|| SecurityError::UnknownUser(id.clone()))
}

pub(super) fn first_admin(connection: &Connection) -> Result<Option<UserId>, SecurityError> {
    Ok(connection
        .query_row(
            "SELECT id FROM users WHERE role = 'admin' ORDER BY created_at, rowid LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?)
}

fn insert_user(connection: &Connection, stamp: &Stamp, name: &str, role: Role) -> Result<User, SecurityError> {
    let taken = connection
        .query_row("SELECT 1 FROM users WHERE lower(name) = lower(?1)", [name], |_| Ok(()))
        .optional()?
        .is_some();
    if taken {
        return Err(SecurityError::NameTaken(name.to_string()));
    }
    let user = User {
        id: UserId(random_uuid()?),
        name: name.to_string(),
        tailnet_user_id: None,
        login: None,
        role,
        created_at: stamp.at,
    };
    connection.execute(
        "INSERT INTO users(id, name, role, created_at) VALUES (?1, ?2, ?3, ?4)",
        (&user.id, &user.name, user.role, user.created_at),
    )?;
    stamp.record(connection, "user.create", &format!("user={} name={} role={}", user.id, user.name, role.as_str()))?;
    Ok(user)
}

fn admin_count(connection: &Connection) -> rusqlite::Result<i64> {
    connection.query_row("SELECT COUNT(*) FROM users WHERE role = 'admin'", [], |row| row.get(0))
}

impl Store {
    /// Adds a user. Names are unique ignoring case.
    pub async fn create_user(&self, name: &str, role: Role) -> Result<User, SecurityError> {
        let name = clean_name(name)?;
        self.write(move |transaction, stamp| insert_user(transaction, stamp, &name, role)).await
    }

    /// The user with `id`, `None` when there is none.
    pub async fn get_user(&self, id: &UserId) -> Result<Option<User>, SecurityError> {
        let id = id.clone();
        self.read(move |connection| {
            Ok(connection
                .query_row(&format!("SELECT {USER_COLUMNS} FROM users WHERE id = ?1"), [&id], user_from_row)
                .optional()?)
        })
        .await
    }

    /// The user called `name`, ignoring case, `None` when there is none.
    pub async fn find_user_by_name(&self, name: &str) -> Result<Option<User>, SecurityError> {
        let name = name.trim().to_string();
        self.read(move |connection| {
            Ok(connection
                .query_row(
                    &format!("SELECT {USER_COLUMNS} FROM users WHERE lower(name) = lower(?1)"),
                    [&name],
                    user_from_row,
                )
                .optional()?)
        })
        .await
    }

    /// Every user, oldest first.
    pub async fn list_users(&self) -> Result<Vec<User>, SecurityError> {
        self.read(|connection| {
            let mut statement = connection.prepare(&format!("SELECT {USER_COLUMNS} FROM users ORDER BY created_at, rowid"))?;
            let users = statement.query_map([], user_from_row)?.collect::<Result<Vec<_>, _>>()?;
            Ok(users)
        })
        .await
    }

    /// Gives `id` the role `role`. The last admin cannot be demoted.
    pub async fn set_role(&self, id: &UserId, role: Role) -> Result<(), SecurityError> {
        let id = id.clone();
        self.write(move |transaction, stamp| {
            let user = require_user(transaction, &id)?;
            if user.role == role {
                return Ok(());
            }
            if user.role == Role::Admin && admin_count(transaction)? <= 1 {
                return Err(SecurityError::LastAdmin);
            }
            transaction.execute("UPDATE users SET role = ?1 WHERE id = ?2", (role, &id))?;
            stamp.record(transaction, "role.set", &format!("user={id} from={} to={}", user.role.as_str(), role.as_str()))?;
            Ok(())
        })
        .await
    }

    /// The first admin, made with `name` when the server has none yet.
    pub async fn ensure_owner(&self, name: &str) -> Result<User, SecurityError> {
        let name = clean_name(name)?;
        self.write(move |transaction, stamp| match first_admin(transaction)? {
            Some(id) => require_user(transaction, &id),
            None => insert_user(transaction, stamp, &name, Role::Admin),
        })
        .await
    }
}
