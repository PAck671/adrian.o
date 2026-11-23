.class final Lcom/adriantools/tvcontrol/Listener;
.super Ljava/lang/Object;
.implements Ljava/lang/Runnable;

# Listens only on the Tailscale address, so the hub is never open on the home Wi-Fi or the internet.

.field final bridge:Lcom/adriantools/tvcontrol/Bridge;
.field next:I
.field final port:I

.method constructor <init>(Lcom/adriantools/tvcontrol/Bridge;I)V
    .registers 4
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/adriantools/tvcontrol/Listener;->bridge:Lcom/adriantools/tvcontrol/Bridge;
    iput p2, p0, Lcom/adriantools/tvcontrol/Listener;->port:I
    const v0, 0xf4240
    iput v0, p0, Lcom/adriantools/tvcontrol/Listener;->next:I
    return-void
.end method

.method static address()Ljava/net/InetAddress;
    .registers 5
    const/4 v1, 0x0
    const-string v0, "tun0"
    invoke-static {v0}, Ljava/net/NetworkInterface;->getByName(Ljava/lang/String;)Ljava/net/NetworkInterface;
    move-result-object v0
    if-eqz v0, :none
    invoke-virtual {v0}, Ljava/net/NetworkInterface;->getInetAddresses()Ljava/util/Enumeration;
    move-result-object v0

    :loop
    invoke-interface {v0}, Ljava/util/Enumeration;->hasMoreElements()Z
    move-result v2
    if-eqz v2, :none
    invoke-interface {v0}, Ljava/util/Enumeration;->nextElement()Ljava/lang/Object;
    move-result-object v2
    check-cast v2, Ljava/net/InetAddress;
    instance-of v3, v2, Ljava/net/Inet4Address;
    if-eqz v3, :loop
    invoke-virtual {v2}, Ljava/net/InetAddress;->getAddress()[B
    move-result-object v3
    const/4 v4, 0x0
    aget-byte v3, v3, v4
    const/16 v4, 0x64
    if-ne v3, v4, :loop
    return-object v2

    :none
    return-object v1
.end method

.method public run()V
    .registers 8

    :again
    :try_start
    invoke-static {}, Lcom/adriantools/tvcontrol/Listener;->address()Ljava/net/InetAddress;
    move-result-object v0
    if-eqz v0, :wait
    new-instance v1, Ljava/net/ServerSocket;
    iget v2, p0, Lcom/adriantools/tvcontrol/Listener;->port:I
    const/16 v3, 0x8
    invoke-direct {v1, v2, v3, v0}, Ljava/net/ServerSocket;-><init>(IILjava/net/InetAddress;)V

    :accept
    invoke-virtual {v1}, Ljava/net/ServerSocket;->accept()Ljava/net/Socket;
    move-result-object v2
    new-instance v3, Lcom/adriantools/tvcontrol/Conn;
    iget v4, p0, Lcom/adriantools/tvcontrol/Listener;->next:I
    add-int/lit8 v5, v4, 0x1
    iput v5, p0, Lcom/adriantools/tvcontrol/Listener;->next:I
    iget-object v5, p0, Lcom/adriantools/tvcontrol/Listener;->bridge:Lcom/adriantools/tvcontrol/Bridge;
    invoke-direct {v3, v5, v4, v2}, Lcom/adriantools/tvcontrol/Conn;-><init>(Lcom/adriantools/tvcontrol/Bridge;ILjava/net/Socket;)V
    goto :accept
    :try_end
    .catch Ljava/lang/Exception; {:try_start .. :try_end} :caught

    :caught
    move-exception v0

    :wait
    const-wide/16 v0, 0x1388
    invoke-static {v0, v1}, Ljava/lang/Thread;->sleep(J)V
    goto :again
.end method
