#ifndef LIBSSH2_H
#define LIBSSH2_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/socket.h>

/* Opaque types */
typedef struct _LIBSSH2_SESSION LIBSSH2_SESSION;
typedef struct _LIBSSH2_CHANNEL LIBSSH2_CHANNEL;
typedef struct _LIBSSH2_LISTENER LIBSSH2_LISTENER;
typedef struct _LIBSSH2_SFTP LIBSSH2_SFTP;
typedef struct _LIBSSH2_SFTP_HANDLE LIBSSH2_SFTP_HANDLE;

struct _LIBSSH2_SFTP_ATTRIBUTES {
    unsigned long flags;
    uint64_t filesize;
    unsigned long uid, gid;
    unsigned long permissions;
    unsigned long atime, mtime;
};
typedef struct _LIBSSH2_SFTP_ATTRIBUTES LIBSSH2_SFTP_ATTRIBUTES;

/* SFTP constants */
#define LIBSSH2_SFTP_ATTR_SIZE          0x00000001
#define LIBSSH2_SFTP_ATTR_UIDGID        0x00000002
#define LIBSSH2_SFTP_ATTR_PERMISSIONS   0x00000004
#define LIBSSH2_SFTP_ATTR_ACMODTIME     0x00000008

#define LIBSSH2_FXF_READ     0x00000001
#define LIBSSH2_FXF_WRITE    0x00000002
#define LIBSSH2_FXF_CREAT    0x00000008
#define LIBSSH2_FXF_TRUNC    0x00000010

/* === Session (wrapper functions) === */
LIBSSH2_SESSION *libssh2_session_init(void);
int libssh2_session_handshake(LIBSSH2_SESSION *session, int sock);
int libssh2_session_disconnect(LIBSSH2_SESSION *session, const char *description);
int libssh2_session_free(LIBSSH2_SESSION *session);
int libssh2_session_last_error(LIBSSH2_SESSION *session, char **errmsg, int *errmsg_len, int want_buf);
int libssh2_session_last_errno(LIBSSH2_SESSION *session);
const char *libssh2_hostkey_hash(LIBSSH2_SESSION *session, int hash_type);
const char *libssh2_session_hostkey(LIBSSH2_SESSION *session, size_t *len, int *type);
void libssh2_session_set_blocking(LIBSSH2_SESSION *session, int blocking);
void libssh2_session_set_timeout(LIBSSH2_SESSION *session, long timeout);
int libssh2_keepalive_send(LIBSSH2_SESSION *session, int *seconds_to_next);
void libssh2_keepalive_config(LIBSSH2_SESSION *session, int want_reply, unsigned int interval);

/* === Authentication (wrapper functions) === */
int libssh2_userauth_password(LIBSSH2_SESSION *session, const char *username, const char *password);
int libssh2_userauth_publickey_fromfile(LIBSSH2_SESSION *session, const char *username, const char *publickey, const char *privatekey, const char *passphrase);
int libssh2_userauth_authenticated(LIBSSH2_SESSION *session);

/* === Channel (wrapper functions) === */
LIBSSH2_CHANNEL *libssh2_channel_open_session(LIBSSH2_SESSION *session);
ssize_t libssh2_channel_read(LIBSSH2_CHANNEL *channel, char *buf, size_t buflen);
ssize_t libssh2_channel_write(LIBSSH2_CHANNEL *channel, const char *buf, size_t buflen);
int libssh2_channel_shell(LIBSSH2_CHANNEL *channel);
int libssh2_channel_exec(LIBSSH2_CHANNEL *channel, const char *command);
int libssh2_channel_setenv(LIBSSH2_CHANNEL *channel, const char *name, const char *value);
int libssh2_channel_request_pty(LIBSSH2_CHANNEL *channel);
int libssh2_channel_request_pty_size(LIBSSH2_CHANNEL *channel, int width, int height);
int libssh2_channel_close(LIBSSH2_CHANNEL *channel);
int libssh2_channel_free(LIBSSH2_CHANNEL *channel);
int libssh2_channel_get_exit_status(LIBSSH2_CHANNEL *channel);

/* === SFTP (wrapper functions) === */
LIBSSH2_SFTP *libssh2_sftp_init(LIBSSH2_SESSION *session);
int libssh2_sftp_shutdown(LIBSSH2_SFTP *sftp);
LIBSSH2_SFTP_HANDLE *libssh2_sftp_open(LIBSSH2_SFTP *sftp, const char *filename, unsigned int filename_len, unsigned long flags, long mode);
int libssh2_sftp_close(LIBSSH2_SFTP_HANDLE *handle);
ssize_t libssh2_sftp_read(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t buffer_maxlen);
ssize_t libssh2_sftp_write(LIBSSH2_SFTP_HANDLE *handle, const char *buffer, size_t count);
LIBSSH2_SFTP_HANDLE *libssh2_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path, unsigned int path_len);
int libssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t buffer_maxlen, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int libssh2_sftp_closedir(LIBSSH2_SFTP_HANDLE *handle);
int libssh2_sftp_unlink(LIBSSH2_SFTP *sftp, const char *filename, unsigned int filename_len);
int libssh2_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, unsigned int path_len, long mode);

/* === SSH Agent === */
typedef struct _LIBSSH2_AGENT LIBSSH2_AGENT;

struct libssh2_agent_publickey {
    struct libssh2_agent_publickey *next;
    int magic;
    void *node;
    unsigned int blen;
    unsigned int alen;
    char *comment;
    unsigned char *blob;
};

LIBSSH2_AGENT *libssh2_agent_init(LIBSSH2_SESSION *session);
int libssh2_agent_connect(LIBSSH2_AGENT *agent);
int libssh2_agent_list_identities(LIBSSH2_AGENT *agent);
int libssh2_agent_get_identity(LIBSSH2_AGENT *agent, struct libssh2_agent_publickey **store, struct libssh2_agent_publickey *prev);
int libssh2_agent_userauth(LIBSSH2_AGENT *agent, const char *username, struct libssh2_agent_publickey *identity);
int libssh2_agent_disconnect(LIBSSH2_AGENT *agent);
void libssh2_agent_free(LIBSSH2_AGENT *agent);

/* === Port Forwarding === */
LIBSSH2_LISTENER *libssh2_channel_forward_listen_ex(LIBSSH2_SESSION *session, const char *host, int port, int *bound_port, int queue_maxsize);
LIBSSH2_CHANNEL *libssh2_channel_forward_accept(LIBSSH2_LISTENER *listener);
LIBSSH2_CHANNEL *libssh2_channel_direct_tcpip_ex(LIBSSH2_SESSION *session, const char *host, int port, const char *shost, int sport);

/* === Internal _ex functions (called from wrapper.c) === */
#define SSH_DISCONNECT_BY_APPLICATION 11
LIBSSH2_SESSION *libssh2_session_init_ex(void *(*alloc)(size_t), void (*freefn)(void*), void *(*reallocfn)(void*, size_t), void *abstract);
int libssh2_session_disconnect_ex(LIBSSH2_SESSION *session, int reason, const char *description, const char *lang);
LIBSSH2_CHANNEL *libssh2_channel_open_ex(LIBSSH2_SESSION *session, const char *channel_type, unsigned int channel_type_len, unsigned int window_size, unsigned int packet_size, const char *message, unsigned int message_len);
int libssh2_channel_process_startup(LIBSSH2_CHANNEL *channel, const char *request, unsigned int request_len, const char *message, unsigned int message_len);
ssize_t libssh2_channel_read_ex(LIBSSH2_CHANNEL *channel, int stream_id, char *buf, size_t buflen);
ssize_t libssh2_channel_write_ex(LIBSSH2_CHANNEL *channel, int stream_id, const char *buf, size_t buflen);
int libssh2_channel_request_pty_ex(LIBSSH2_CHANNEL *channel, const char *term, unsigned int term_len, const char *modes, unsigned int modes_len, int width, int height, int width_px, int height_px);
int libssh2_channel_request_pty_size_ex(LIBSSH2_CHANNEL *channel, int width, int height);
int libssh2_channel_setenv_ex(LIBSSH2_CHANNEL *channel, const char *name, unsigned int name_len, const char *value, unsigned int value_len);
int libssh2_userauth_password_ex(LIBSSH2_SESSION *session, const char *username, unsigned int username_len, const char *password, unsigned int password_len, void *passwd_change_cb);
int libssh2_userauth_publickey_fromfile_ex(LIBSSH2_SESSION *session, const char *username, unsigned int username_len, const char *publickey, const char *privatekey, const char *passphrase);

LIBSSH2_SFTP_HANDLE *libssh2_sftp_open_ex(LIBSSH2_SFTP *sftp, const char *filename, unsigned int filename_len, unsigned long flags, long mode, int open_type);
int libssh2_sftp_close_handle(LIBSSH2_SFTP_HANDLE *handle);
ssize_t libssh2_sftp_read(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t buffer_maxlen);
ssize_t libssh2_sftp_write(LIBSSH2_SFTP_HANDLE *handle, const char *buffer, size_t count);
int libssh2_sftp_readdir_ex(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t buffer_maxlen, char *longentry, size_t longentry_maxlen, LIBSSH2_SFTP_ATTRIBUTES *attrs);
int libssh2_sftp_unlink_ex(LIBSSH2_SFTP *sftp, const char *filename, unsigned int filename_len);
int libssh2_sftp_mkdir_ex(LIBSSH2_SFTP *sftp, const char *path, unsigned int path_len, long mode);

#endif
