package ir.r3r.river_player;

import androidx.media3.common.PlaybackException;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.ExoPlaybackException;
import java.io.InterruptedIOException;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.nio.channels.ClosedChannelException;
import java.security.GeneralSecurityException;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import java.util.concurrent.CancellationException;
import javax.net.ssl.SSLException;

/** Classifies backend failures without treating every source error as a retry. */
final class BackendRetryability {
    private BackendRetryability() {}

    static boolean isRetryable(PlaybackException error) {
        if (error instanceof ExoPlaybackException
                && ((ExoPlaybackException) error).type != ExoPlaybackException.TYPE_SOURCE) {
            return false;
        }
        switch (error.errorCode) {
            case PlaybackException.ERROR_CODE_IO_UNSPECIFIED:
            case PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED:
            case PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT:
            case PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS:
                break;
            default:
                return false;
        }

        Integer status = null;
        boolean networkFailure = false;
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        for (Throwable cause = error; cause != null && seen.add(cause); cause = cause.getCause()) {
            // Inspect the full chain before accepting an outer network wrapper.
            if (cause instanceof SSLException
                    || cause instanceof GeneralSecurityException
                    || cause instanceof CancellationException
                    || cause instanceof InterruptedException
                    || cause instanceof ClosedChannelException
                    || (cause instanceof InterruptedIOException
                        && !(cause instanceof SocketTimeoutException))) {
                return false;
            }
            if (cause instanceof HttpDataSource.InvalidResponseCodeException) {
                int code = ((HttpDataSource.InvalidResponseCodeException) cause).responseCode;
                if (code != 502 && code != 503 && code != 504) return false;
                status = code;
            }
            // OkHttp cancellation may surface as a plain IOException or closed
            // socket rather than CancellationException. Never rotate for these.
            String message = cause.getMessage();
            if ("Canceled".equalsIgnoreCase(message)
                    || "Cancelled".equalsIgnoreCase(message)
                    || "Socket closed".equalsIgnoreCase(message)
                    || "Socket is closed".equalsIgnoreCase(message)) {
                return false;
            }
            if (cause instanceof SocketTimeoutException
                    || cause instanceof SocketException
                    || cause instanceof UnknownHostException) {
                networkFailure = true;
            }
        }
        return status != null
                || networkFailure
                || error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT;
    }
}
