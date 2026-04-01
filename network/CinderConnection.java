package dev.cinder.network;

import dev.cinder.chunk.ChunkLifecycleManager;
import dev.cinder.entity.EntityUpdatePipeline;
import dev.cinder.entity.PlayerEntity;
import dev.cinder.network.PacketCodec.InboundAction;
import dev.cinder.server.CinderScheduler;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.SocketChannel;
import java.util.ArrayDeque;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;
import java.util.logging.Logger;

/**
 * Per-player connection state and IO pipeline.
 *
 * <p>Owns:
 * <ul>
 *   <li>The {@link SocketChannel} for this connection</li>
 *   <li>An inbound read buffer (heap, pooled sizing)</li>
 *   <li>An outbound write queue (direct buffers for zero-copy on write)</li>
 *   <li>A {@link ProtocolState} state machine tracking handshake → login → play lifecycle</li>
 * </ul>
 *
 * <p>Threading contract:
 * <ul>
 *   <li>{@link #readInbound()} is called only from {@code cinder-net-accept}</li>
 *   <li>{@link #enqueuePacket(ByteBuffer)} may be called from {@code cinder-tick} (POST phase)</li>
 *   <li>{@link #flushOutbound()} is called from {@code cinder-net-write} workers</li>
 *   <li>{@link #close(String)} is safe to call from any thread</li>
 * </ul>
 *
 * <p>PROXY protocol v2 header (if enabled) is consumed transparently before any
 * Minecraft protocol bytes are processed. The real client IP replaces the socket
 * peer address for logging and rate-limiting purposes after header parse.
 */
public final class CinderConnection {

    private static final Logger LOG = Logger.getLogger("cinder.network");

    /**
     * Minecraft protocol lifecycle states.
     * Transitions: PROXY_HEADER → HANDSHAKE → LOGIN → PLAY (terminal for normal sessions)
     * PROXY_HEADER is skipped when proxy protocol is disabled.
     */
    public enum ProtocolState {
        PROXY_HEADER,
        HANDSHAKE,
        LOGIN,
        PLAY,
        CLOSING
    }

    // PROXY protocol v2 signature (12 bytes).
    private static final byte[] PROXY_V2_SIGNATURE = {
            0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A
    };
    private static final int PROXY_V2_HEADER_MIN = 16; // fixed header before additional data

    // Read buffer: 64 KB covers the largest legitimate Minecraft packet (chunk data).
    // Allocated once per connection; not pooled (Pi 4 has enough heap at this scale).
    private static final int READ_BUFFER_CAPACITY = 65536;

    // Write queue capacity guard — prevents unbounded memory growth if a client stalls.
    private static final int MAX_WRITE_QUEUE_BYTES = 4 * 1024 * 1024; // 4 MB per connection

    private final SocketChannel socketChannel;
    private InetSocketAddress remoteAddress; // may be replaced by PROXY header
    private final CinderScheduler scheduler;
    private final Executor writeExecutor;
    private final boolean proxyProtocolEnabled;
    private final Consumer<CinderConnection> closeCallback;
    private final EntityUpdatePipeline entityPipeline;
    private final ChunkLifecycleManager chunkManager;
    private volatile int viewDistance;

    private SelectionKey selectionKey;

    // Inbound state — only touched by cinder-net-accept.
    private final ByteBuffer readBuffer = ByteBuffer.allocate(READ_BUFFER_CAPACITY);
    private ProtocolState state;

    // For PROXY v2 parsing: track whether we have the fixed header yet.
    private boolean proxyHeaderParsed = false;

    // Outbound state — written by cinder-tick POST, flushed by cinder-net-write.
    // GuardedBy: outboundLock
    private final ArrayDeque<ByteBuffer> writeQueue = new ArrayDeque<>();
    private int writeQueueBytes = 0;
    private final Object outboundLock = new Object();

    private final AtomicBoolean closed = new AtomicBoolean(false);

    // Connection-level identity — set after successful LOGIN.
    private volatile String playerName = null;
    private volatile java.util.UUID playerUuid = null;
    // Set on the tick thread after LOGIN; referenced during PLAY dispatch.
    private volatile PlayerEntity playerEntity = null;

    // Metrics.
    private long bytesRead = 0;
    private long bytesWritten = 0;
    private long packetsDecoded = 0;

    public CinderConnection(
            SocketChannel socketChannel,
            InetSocketAddress remoteAddress,
            CinderScheduler scheduler,
            Executor writeExecutor,
            boolean proxyProtocolEnabled,
            Consumer<CinderConnection> closeCallback,
            EntityUpdatePipeline entityPipeline,
            ChunkLifecycleManager chunkManager,
            int viewDistance) {
        this.socketChannel = socketChannel;
        this.remoteAddress = remoteAddress;
        this.scheduler = scheduler;
        this.writeExecutor = writeExecutor;
        this.proxyProtocolEnabled = proxyProtocolEnabled;
        this.closeCallback = closeCallback;
        this.entityPipeline = entityPipeline;
        this.chunkManager = chunkManager;
        this.viewDistance = Math.max(2, Math.min(viewDistance, 32));
        this.state = proxyProtocolEnabled ? ProtocolState.PROXY_HEADER : ProtocolState.HANDSHAKE;
    }

    // -------------------------------------------------------------------------
    // Inbound (cinder-net-accept thread)
    // -------------------------------------------------------------------------

    /**
     * Read available bytes from the channel into the read buffer, then dispatch.
     * Called by the selector loop whenever OP_READ fires.
     */
    public void readInbound() throws IOException {
        int read = socketChannel.read(readBuffer);
        if (read == -1) {
            close("remote closed connection");
            return;
        }
        if (read == 0) return;
        bytesRead += read;

        // Flip to read mode, dispatch, then compact residual bytes back to write position.
        readBuffer.flip();
        dispatchInbound();
        readBuffer.compact();
    }

    /**
     * Consume all complete protocol units from the read buffer.
     */
    private void dispatchInbound() {
        while (readBuffer.hasRemaining() && state != ProtocolState.CLOSING) {
            boolean progress;
            switch (state) {
                case PROXY_HEADER -> progress = tryConsumeProxyHeader();
                case HANDSHAKE    -> progress = tryConsumeHandshake();
                case LOGIN        -> progress = tryConsumeLogin();
                case PLAY         -> progress = tryConsumePlay();
                default           -> { return; }
            }
            if (!progress) break; // need more bytes
        }
    }

    // -------------------------------------------------------------------------
    // Protocol state handlers
    // -------------------------------------------------------------------------

    /**
     * Parse PROXY protocol v2 fixed header + address block.
     * Returns true if the header was fully consumed and state advanced.
     */
    private boolean tryConsumeProxyHeader() {
        if (proxyHeaderParsed) {
            state = ProtocolState.HANDSHAKE;
            return true;
        }

        int available = readBuffer.remaining();
        if (available < PROXY_V2_HEADER_MIN) return false;

        // Verify signature.
        readBuffer.mark();
        byte[] sig = new byte[12];
        readBuffer.get(sig);
        for (int i = 0; i < PROXY_V2_SIGNATURE.length; i++) {
            if (sig[i] != PROXY_V2_SIGNATURE[i]) {
                // Not a PROXY v2 header — treat as direct connection (misconfiguration or test).
                LOG.fine("[network] No PROXY v2 header from " + remoteAddress + "; treating as direct.");
                readBuffer.reset();
                proxyHeaderParsed = true;
                state = ProtocolState.HANDSHAKE;
                return true;
            }
        }

        // Byte 12: version+command. Byte 13: family. Bytes 14-15: length of additional address info.
        byte verCmd = readBuffer.get();  // 0xXY — X=version (must be 2), Y=command
        byte family = readBuffer.get();  // address family + protocol
        short addrLen = readBuffer.getShort(); // remaining header bytes

        int version = (verCmd >> 4) & 0xF;
        int command = verCmd & 0xF;

        if (version != 2) {
            close("invalid PROXY protocol version: " + version);
            return false;
        }

        int totalAdditional = Short.toUnsignedInt(addrLen);
        if (available < PROXY_V2_HEADER_MIN + totalAdditional) {
            // Need more bytes.
            readBuffer.reset();
            return false;
        }

        // command 0x1 = PROXY (forward real address), 0x0 = LOCAL (health check, ignore).
        if (command == 0x01) {
            int addressFamily = (family >> 4) & 0xF; // 0x1=IPv4, 0x2=IPv6, 0x3=Unix
            parseProxyAddress(addressFamily, totalAdditional);
        } else {
            // LOCAL command — skip address block.
            readBuffer.position(readBuffer.position() + totalAdditional);
        }

        proxyHeaderParsed = true;
        state = ProtocolState.HANDSHAKE;
        return true;
    }

    private void parseProxyAddress(int addressFamily, int addrBlockLen) {
        try {
            if (addressFamily == 0x1 && addrBlockLen >= 12) {
                // IPv4: src_addr(4) + dst_addr(4) + src_port(2) + dst_port(2)
                byte[] src = new byte[4];
                readBuffer.get(src);
                readBuffer.position(readBuffer.position() + 4); // skip dst addr
                int srcPort = Short.toUnsignedInt(readBuffer.getShort());
                readBuffer.position(readBuffer.position() + 2); // skip dst port

                java.net.Inet4Address addr = (java.net.Inet4Address) java.net.InetAddress.getByAddress(src);
                remoteAddress = new InetSocketAddress(addr, srcPort);

                if (addrBlockLen > 12) {
                    readBuffer.position(readBuffer.position() + (addrBlockLen - 12));
                }
            } else if (addressFamily == 0x2 && addrBlockLen >= 36) {
                // IPv6: src_addr(16) + dst_addr(16) + src_port(2) + dst_port(2)
                byte[] src = new byte[16];
                readBuffer.get(src);
                readBuffer.position(readBuffer.position() + 16);
                int srcPort = Short.toUnsignedInt(readBuffer.getShort());
                readBuffer.position(readBuffer.position() + 2);

                java.net.Inet6Address addr = (java.net.Inet6Address) java.net.InetAddress.getByAddress(src);
                remoteAddress = new InetSocketAddress(addr, srcPort);

                if (addrBlockLen > 36) {
                    readBuffer.position(readBuffer.position() + (addrBlockLen - 36));
                }
            } else {
                // Unix socket or unknown — skip.
                readBuffer.position(readBuffer.position() + addrBlockLen);
            }
        } catch (java.net.UnknownHostException e) {
            // Shouldn't happen with raw bytes but handle gracefully.
            readBuffer.position(readBuffer.position() + addrBlockLen);
        }
    }

    /**
     * Consume a Minecraft handshake packet.
     *
     * <p>Minecraft packets are length-prefixed with a VarInt. We read enough
     * to determine the packet boundary, then submit decoding as a sync task
     * so the scheduler owns handshake state progression.
     */
    private boolean tryConsumeHandshake() {
        return tryConsumeMinecraftPacket(packetBuf -> {
            // Decoded packet dispatched to tick thread via submitSync.
            // Packet codec will parse fields; for now log and advance state.
            scheduler.submitSync("net:handshake:" + remoteAddress, () -> handleHandshakePacket(packetBuf.duplicate()));
            packetsDecoded++;
        });
    }

    private boolean tryConsumeLogin() {
        return tryConsumeMinecraftPacket(packetBuf -> {
            scheduler.submitSync("net:login:" + remoteAddress, () -> handleLoginPacket(packetBuf.duplicate()));
            packetsDecoded++;
        });
    }

    private boolean tryConsumePlay() {
        return tryConsumeMinecraftPacket(packetBuf -> {
            scheduler.submitSync("net:play:" + playerName, () -> handlePlayPacket(packetBuf.duplicate()));
            packetsDecoded++;
        });
    }

    /**
     * Generic VarInt-length-prefixed packet reader.
     *
     * <p>Reads the VarInt length prefix, verifies enough bytes are present,
     * then slices the packet payload and calls {@code consumer}.
     *
     * @return true if a complete packet was consumed, false if more bytes needed
     */
    private boolean tryConsumeMinecraftPacket(java.util.function.Consumer<ByteBuffer> consumer) {
        readBuffer.mark();

        VarIntResult lenResult = readVarInt(readBuffer);
        if (!lenResult.valid) {
            readBuffer.reset();
            return false;
        }

        int packetLen = lenResult.value;
        if (packetLen < 0 || packetLen > 2097151) { // max 3-byte VarInt payload
            close("invalid packet length: " + packetLen);
            return false;
        }

        if (readBuffer.remaining() < packetLen) {
            readBuffer.reset();
            return false;
        }

        // Slice the packet payload — limit to packetLen bytes from current position.
        int payloadStart = readBuffer.position();
        ByteBuffer payload = readBuffer.slice(payloadStart, packetLen);
        readBuffer.position(payloadStart + packetLen);

        consumer.accept(payload);
        return true;
    }

    // -------------------------------------------------------------------------
    // Packet handlers (executed on cinder-tick via submitSync)
    // -------------------------------------------------------------------------

    private void handleHandshakePacket(ByteBuffer payload) {
        // Packet 0x00 — Handshake
        // Fields: protocol_version (VarInt), server_address (String), server_port (unsigned short),
        //         next_state (VarInt): 1=status, 2=login
        VarIntResult packetId = readVarInt(payload);
        if (!packetId.valid || packetId.value != 0x00) {
            close("unexpected handshake packet id: " + (packetId.valid ? packetId.value : "?"));
            return;
        }

        VarIntResult protocolVersion = readVarInt(payload);
        String serverAddress = readString(payload, 255);
        if (payload.remaining() < 3) { close("truncated handshake"); return; }
        int serverPort = Short.toUnsignedInt(payload.getShort());
        VarIntResult nextState = readVarInt(payload);

        if (!protocolVersion.valid || !nextState.valid) { close("malformed handshake"); return; }

        LOG.fine("[network] Handshake from " + remoteAddress
                + " proto=" + protocolVersion.value
                + " nextState=" + nextState.value);

        switch (nextState.value) {
            case 1 -> state = ProtocolState.LOGIN; // status — treat same pipeline for now
            case 2 -> state = ProtocolState.LOGIN;
            default -> close("invalid next_state: " + nextState.value);
        }
    }

    private void handleLoginPacket(ByteBuffer payload) {
        // Packet 0x00 — Login Start
        // Fields: name (String, max 16), has_uuid (Boolean), uuid (optional UUID)
        VarIntResult packetId = readVarInt(payload);
        if (!packetId.valid || packetId.value != 0x00) {
            close("unexpected login packet id: " + (packetId.valid ? packetId.value : "?"));
            return;
        }

        String name = readString(payload, 16);
        if (name == null || name.isEmpty()) { close("empty player name"); return; }

        java.util.UUID uuid = java.util.UUID.nameUUIDFromBytes(
                ("OfflinePlayer:" + name).getBytes(java.nio.charset.StandardCharsets.UTF_8));

        if (payload.hasRemaining()) {
            boolean hasUuid = payload.get() != 0;
            if (hasUuid && payload.remaining() >= 16) {
                long msb = payload.getLong();
                long lsb = payload.getLong();
                uuid = new java.util.UUID(msb, lsb);
            }
        }

        this.playerName = name;
        this.playerUuid = uuid;

        LOG.info("[network] Login: " + name + " uuid=" + uuid + " from=" + remoteAddress);

        // Send Login Success (0x02) to transition client to PLAY state.
        sendLoginSuccess(uuid, name);
        state = ProtocolState.PLAY;

        // Construct and register the PlayerEntity on the tick thread.
        // CinderConnection is now in PLAY state; the entity's onSpawn() will
        // send Login (Play) and the initial position sync.
        final String playerNameFinal = name;
        scheduler.submitSync("net:spawn:" + name, () -> {
            PlayerEntity entity = new PlayerEntity(this, chunkManager, viewDistance);
            entityPipeline.register(entity, dev.cinder.entity.EntityUpdatePipeline.EntityTier.CRITICAL);
            this.playerEntity = entity;
            entity.spawn();
            LOG.info("[network] PlayerEntity registered: " + playerNameFinal
                    + " entityId=" + entity.getEntityId());
        });
    }

    private void handlePlayPacket(ByteBuffer payload) {
        if (playerEntity == null) {
            // PlayerEntity not yet registered — tick thread is still processing the spawn task.
            // Silently discard; client will resend time-sensitive packets (keep-alive, movement).
            return;
        }
        try {
            InboundAction action = PacketCodec.decode(payload);
            playerEntity.enqueueAction(action);
            packetsDecoded++;
        } catch (PacketCodec.DecodeException e) {
            LOG.fine("[network] Decode error from " + playerName + ": " + e.getMessage());
            close("protocol error: " + e.getMessage());
        }
    }

    // -------------------------------------------------------------------------
    // Outbound
    // -------------------------------------------------------------------------

    /**
     * Enqueue a fully-encoded packet buffer for delivery.
     * May be called from any thread. Thread-safe.
     *
     * <p>The buffer will be written as-is — callers must ensure it is a complete,
     * length-prefixed Minecraft packet ready for the wire.
     */
    public void enqueuePacket(ByteBuffer packet) {
        if (closed.get()) return;

        synchronized (outboundLock) {
            if (writeQueueBytes + packet.remaining() > MAX_WRITE_QUEUE_BYTES) {
                LOG.warning("[network] Write buffer overflow for " + playerName
                        + " — closing connection");
                close("write buffer overflow");
                return;
            }
            // Defensive copy — caller may reuse the buffer.
            ByteBuffer copy = ByteBuffer.allocateDirect(packet.remaining());
            copy.put(packet);
            copy.flip();
            writeQueue.addLast(copy);
            writeQueueBytes += copy.limit();
        }
    }

    /**
     * Flush all enqueued outbound buffers to the socket.
     * Called from {@code cinder-net-write} workers during POST phase.
     */
    public void flushOutbound() {
        if (closed.get()) return;

        ByteBuffer[] toWrite;
        int totalBytes;
        synchronized (outboundLock) {
            if (writeQueue.isEmpty()) return;
            toWrite = writeQueue.toArray(new ByteBuffer[0]);
            totalBytes = writeQueueBytes;
            writeQueue.clear();
            writeQueueBytes = 0;
        }

        // Gather-write: OS-level scatter/gather IO reduces syscall overhead on Pi 4.
        try {
            long written = socketChannel.write(toWrite);
            bytesWritten += written;

            if (written < totalBytes) {
                // Short write — re-queue unwritten remainder.
                synchronized (outboundLock) {
                    for (ByteBuffer buf : toWrite) {
                        if (buf.hasRemaining()) {
                            writeQueue.addFirst(buf);
                            writeQueueBytes += buf.remaining();
                        }
                    }
                }
            }
        } catch (IOException e) {
            close("write error: " + e.getMessage());
        }
    }

    public boolean hasPendingWrites() {
        synchronized (outboundLock) {
            return !writeQueue.isEmpty();
        }
    }

    // -------------------------------------------------------------------------
    // Outbound packet builders
    // -------------------------------------------------------------------------

    private void sendLoginSuccess(java.util.UUID uuid, String name) {
        // Packet 0x02 — Login Success
        // Fields: uuid (UUID as 128-bit), name (String), number_of_properties (VarInt)
        byte[] nameBytes = name.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        ByteBuffer payload = ByteBuffer.allocate(1 + 16 + 1 + nameBytes.length + 1);
        writeVarInt(payload, 0x02);        // packet id
        payload.putLong(uuid.getMostSignificantBits());
        payload.putLong(uuid.getLeastSignificantBits());
        writeVarInt(payload, nameBytes.length); // string length prefix
        payload.put(nameBytes);
        writeVarInt(payload, 0);           // number of properties = 0
        payload.flip();

        ByteBuffer framed = framePacket(payload);
        enqueuePacket(framed);
        writeExecutor.execute(this::flushOutbound); // push login success immediately
    }

    /**
     * Wrap a payload buffer with a VarInt length prefix.
     */
    private static ByteBuffer framePacket(ByteBuffer payload) {
        int len = payload.remaining();
        // VarInt for len is at most 3 bytes for Minecraft packet sizes.
        byte[] lenBytes = encodeVarInt(len);
        ByteBuffer framed = ByteBuffer.allocateDirect(lenBytes.length + len);
        framed.put(lenBytes);
        framed.put(payload);
        framed.flip();
        return framed;
    }

    // -------------------------------------------------------------------------
    // VarInt encode/decode
    // -------------------------------------------------------------------------

    static final class VarIntResult {
        final boolean valid;
        final int value;
        final int bytesConsumed;

        VarIntResult(boolean valid, int value, int bytesConsumed) {
            this.valid = valid;
            this.value = value;
            this.bytesConsumed = bytesConsumed;
        }
    }

    /**
     * Decode a VarInt from the buffer's current position, advancing it on success.
     * Returns invalid result (not advancing buffer) if not enough bytes are available.
     */
    static VarIntResult readVarInt(ByteBuffer buf) {
        int value = 0;
        int shift = 0;
        int startPos = buf.position();

        while (buf.hasRemaining()) {
            if (shift >= 35) {
                buf.position(startPos);
                return new VarIntResult(false, 0, 0); // too many bytes — protocol error
            }
            byte b = buf.get();
            value |= (b & 0x7F) << shift;
            shift += 7;
            if ((b & 0x80) == 0) {
                return new VarIntResult(true, value, buf.position() - startPos);
            }
        }

        // Not enough bytes yet.
        buf.position(startPos);
        return new VarIntResult(false, 0, 0);
    }

    private static void writeVarInt(ByteBuffer buf, int value) {
        while ((value & ~0x7F) != 0) {
            buf.put((byte) ((value & 0x7F) | 0x80));
            value >>>= 7;
        }
        buf.put((byte) value);
    }

    private static byte[] encodeVarInt(int value) {
        byte[] tmp = new byte[5];
        int i = 0;
        while ((value & ~0x7F) != 0) {
            tmp[i++] = (byte) ((value & 0x7F) | 0x80);
            value >>>= 7;
        }
        tmp[i++] = (byte) value;
        byte[] result = new byte[i];
        System.arraycopy(tmp, 0, result, 0, i);
        return result;
    }

    /**
     * Read a length-prefixed UTF-8 string from the buffer.
     * Returns null if the buffer does not contain a complete string.
     */
    private static String readString(ByteBuffer buf, int maxLen) {
        int mark = buf.position();
        VarIntResult lenResult = readVarInt(buf);
        if (!lenResult.valid) { buf.position(mark); return null; }
        int len = lenResult.value;
        if (len < 0 || len > maxLen * 4) { return null; } // max UTF-8 bytes for maxLen chars
        if (buf.remaining() < len) { buf.position(mark); return null; }
        byte[] bytes = new byte[len];
        buf.get(bytes);
        return new String(bytes, java.nio.charset.StandardCharsets.UTF_8);
    }

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    public void close(String reason) {
        if (!closed.compareAndSet(false, true)) return;
        state = ProtocolState.CLOSING;

        LOG.fine("[network] Closing connection [" + remoteAddress + "] reason=" + reason);

        try { socketChannel.close(); } catch (IOException ignored) {}
        closeCallback.accept(this);
    }

    /**
     * Applies a runtime view-distance update for this connection/player.
     * Should be called on the tick thread.
     */
    public void updateViewDistance(int newViewDistance) {
        int clamped = Math.max(2, Math.min(newViewDistance, 32));
        if (clamped == this.viewDistance) {
            return;
        }
        this.viewDistance = clamped;

        PlayerEntity entity = this.playerEntity;
        if (entity != null) {
            entity.updateViewDistance(clamped);
        }
    }

    // -------------------------------------------------------------------------
    // Accessors
    // -------------------------------------------------------------------------

    public SocketChannel channel() { return socketChannel; }
    public InetSocketAddress remoteAddress() { return remoteAddress; }
    public ProtocolState getState() { return state; }
    public String getPlayerName() { return playerName; }
    public java.util.UUID getPlayerUuid() { return playerUuid; }
    public boolean isClosed() { return closed.get(); }

    public void setSelectionKey(SelectionKey key) { this.selectionKey = key; }
    public SelectionKey getSelectionKey() { return selectionKey; }

    public long getBytesRead() { return bytesRead; }
    public long getBytesWritten() { return bytesWritten; }
    public long getPacketsDecoded() { return packetsDecoded; }

    // Called from tick thread to advance state machine directly
    // (e.g. after PlayerEntity is registered, signal play-state begin).
    void transitionTo(ProtocolState newState) {
        this.state = newState;
    }
}
