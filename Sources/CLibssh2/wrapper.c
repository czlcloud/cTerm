#include "include/libssh2.h"
#include <string.h>

LIBSSH2_SESSION *libssh2_session_init(void) {
    return libssh2_session_init_ex(NULL, NULL, NULL, NULL);
}

int libssh2_session_disconnect(LIBSSH2_SESSION *session, const char *description) {
    return libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, description, "");
}

LIBSSH2_CHANNEL *libssh2_channel_open_session(LIBSSH2_SESSION *session) {
    return libssh2_channel_open_ex(session, "session", sizeof("session") - 1, 2*1024*1024, 32768, NULL, 0);
}

int libssh2_channel_shell(LIBSSH2_CHANNEL *channel) {
    return libssh2_channel_process_startup(channel, "shell", sizeof("shell") - 1, NULL, 0);
}

int libssh2_channel_exec(LIBSSH2_CHANNEL *channel, const char *command) {
    return libssh2_channel_process_startup(channel, "exec", sizeof("exec") - 1, command, (unsigned int)strlen(command));
}

ssize_t libssh2_channel_read(LIBSSH2_CHANNEL *channel, char *buf, size_t buflen) {
    return libssh2_channel_read_ex(channel, 0, buf, buflen);
}

ssize_t libssh2_channel_write(LIBSSH2_CHANNEL *channel, const char *buf, size_t buflen) {
    return libssh2_channel_write_ex(channel, 0, buf, buflen);
}

int libssh2_channel_request_pty(LIBSSH2_CHANNEL *channel) {
    return libssh2_channel_request_pty_ex(channel, "xterm-256color", sizeof("xterm-256color") - 1, NULL, 0, 80, 24, 0, 0);
}

int libssh2_channel_request_pty_size(LIBSSH2_CHANNEL *channel, int width, int height) {
    return libssh2_channel_request_pty_size_ex(channel, width, height);
}

int libssh2_channel_setenv(LIBSSH2_CHANNEL *channel, const char *name, const char *value) {
    return libssh2_channel_setenv_ex(channel, name, (unsigned int)strlen(name), value, (unsigned int)strlen(value));
}

int libssh2_userauth_password(LIBSSH2_SESSION *session, const char *username, const char *password) {
    return libssh2_userauth_password_ex(session, username, (unsigned int)strlen(username), password, (unsigned int)strlen(password), NULL);
}

int libssh2_userauth_publickey_fromfile(LIBSSH2_SESSION *session, const char *username, const char *publickey, const char *privatekey, const char *passphrase) {
    return libssh2_userauth_publickey_fromfile_ex(session, username, (unsigned int)strlen(username), publickey, privatekey, passphrase);
}

LIBSSH2_SFTP_HANDLE *libssh2_sftp_open(LIBSSH2_SFTP *sftp, const char *filename, unsigned int filename_len, unsigned long flags, long mode) {
    (void)filename_len;
    return libssh2_sftp_open_ex(sftp, filename, (unsigned int)strlen(filename), flags, mode, 0);
}

int libssh2_sftp_close(LIBSSH2_SFTP_HANDLE *handle) {
    return libssh2_sftp_close_handle(handle);
}

LIBSSH2_SFTP_HANDLE *libssh2_sftp_opendir(LIBSSH2_SFTP *sftp, const char *path, unsigned int path_len) {
    (void)path_len;
    return libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), 0, 0, 1);
}

int libssh2_sftp_readdir(LIBSSH2_SFTP_HANDLE *handle, char *buffer, size_t buffer_maxlen, LIBSSH2_SFTP_ATTRIBUTES *attrs) {
    return libssh2_sftp_readdir_ex(handle, buffer, buffer_maxlen, NULL, 0, attrs);
}

int libssh2_sftp_closedir(LIBSSH2_SFTP_HANDLE *handle) {
    return libssh2_sftp_close_handle(handle);
}

int libssh2_sftp_unlink(LIBSSH2_SFTP *sftp, const char *filename, unsigned int filename_len) {
    (void)filename_len;
    return libssh2_sftp_unlink_ex(sftp, filename, (unsigned int)strlen(filename));
}

int libssh2_sftp_mkdir(LIBSSH2_SFTP *sftp, const char *path, unsigned int path_len, long mode) {
    (void)path_len;
    return libssh2_sftp_mkdir_ex(sftp, path, (unsigned int)strlen(path), mode);
}
