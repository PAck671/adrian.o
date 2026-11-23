.class final Lcom/adriantools/tvcontrol/Conn;
.super Ljava/lang/Object;
.implements Ljava/lang/Runnable;

.field final bridge:Lcom/adriantools/tvcontrol/Bridge;
.field final host:Ljava/lang/String;
.field final id:I
.field volatile out:Ljava/io/OutputStream;
.field final port:I
.field volatile sock:Ljava/net/Socket;
.field final tls:Z

.method constructor <init>(Lcom/adriantools/tvcontrol/Bridge;ILjava/lang/String;IZ)V
    .registers 8
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/adriantools/tvcontrol/Conn;->bridge:Lcom/adriantools/tvcontrol/Bridge;
    iput p2, p0, Lcom/adriantools/tvcontrol/Conn;->id:I
    iput-object p3, p0, Lcom/adriantools/tvcontrol/Conn;->host:Ljava/lang/String;
    iput p4, p0, Lcom/adriantools/tvcontrol/Conn;->port:I
    iput-boolean p5, p0, Lcom/adriantools/tvcontrol/Conn;->tls:Z
    iget-object v0, p1, Lcom/adriantools/tvcontrol/Bridge;->conns:Ljava/util/concurrent/ConcurrentHashMap;
    invoke-static {p2}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object v1
    invoke-virtual {v0, v1, p0}, Ljava/util/concurrent/ConcurrentHashMap;->put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;
    new-instance v0, Ljava/lang/Thread;
    invoke-direct {v0, p0}, Ljava/lang/Thread;-><init>(Ljava/lang/Runnable;)V
    invoke-virtual {v0}, Ljava/lang/Thread;->start()V
    return-void
.end method

.method constructor <init>(Lcom/adriantools/tvcontrol/Bridge;ILjava/net/Socket;)V
    .registers 7
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/adriantools/tvcontrol/Conn;->bridge:Lcom/adriantools/tvcontrol/Bridge;
    iput p2, p0, Lcom/adriantools/tvcontrol/Conn;->id:I
    iput-object p3, p0, Lcom/adriantools/tvcontrol/Conn;->sock:Ljava/net/Socket;
    const-string v0, ""
    iput-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->host:Ljava/lang/String;
    const/4 v0, 0x0
    iput v0, p0, Lcom/adriantools/tvcontrol/Conn;->port:I
    iput-boolean v0, p0, Lcom/adriantools/tvcontrol/Conn;->tls:Z
    iget-object v0, p1, Lcom/adriantools/tvcontrol/Bridge;->conns:Ljava/util/concurrent/ConcurrentHashMap;
    invoke-static {p2}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object v1
    invoke-virtual {v0, v1, p0}, Ljava/util/concurrent/ConcurrentHashMap;->put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;
    new-instance v0, Ljava/lang/Thread;
    invoke-direct {v0, p0}, Ljava/lang/Thread;-><init>(Ljava/lang/Runnable;)V
    invoke-virtual {v0}, Ljava/lang/Thread;->start()V
    return-void
.end method

.method public run()V
    .registers 10
    :try_start
    const-string v4, ""
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->sock:Ljava/net/Socket;
    if-nez v0, :plain
    new-instance v0, Ljava/net/Socket;
    invoke-direct {v0}, Ljava/net/Socket;-><init>()V
    iput-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->sock:Ljava/net/Socket;
    new-instance v1, Ljava/net/InetSocketAddress;
    iget-object v2, p0, Lcom/adriantools/tvcontrol/Conn;->host:Ljava/lang/String;
    iget v3, p0, Lcom/adriantools/tvcontrol/Conn;->port:I
    invoke-direct {v1, v2, v3}, Ljava/net/InetSocketAddress;-><init>(Ljava/lang/String;I)V
    const/16 v2, 0x1f40
    invoke-virtual {v0, v1, v2}, Ljava/net/Socket;->connect(Ljava/net/SocketAddress;I)V
    const/4 v1, 0x1
    invoke-virtual {v0, v1}, Ljava/net/Socket;->setTcpNoDelay(Z)V
    const-string v4, ""
    iget-boolean v1, p0, Lcom/adriantools/tvcontrol/Conn;->tls:Z
    if-eqz v1, :plain

    const-string v1, "TLS"
    invoke-static {v1}, Ljavax/net/ssl/SSLContext;->getInstance(Ljava/lang/String;)Ljavax/net/ssl/SSLContext;
    move-result-object v1
    const/4 v2, 0x1
    new-array v2, v2, [Ljavax/net/ssl/TrustManager;
    new-instance v3, Lcom/adriantools/tvcontrol/TrustAll;
    invoke-direct {v3}, Lcom/adriantools/tvcontrol/TrustAll;-><init>()V
    const/4 v5, 0x0
    aput-object v3, v2, v5
    const/4 v3, 0x0
    invoke-virtual {v1, v3, v2, v3}, Ljavax/net/ssl/SSLContext;->init([Ljavax/net/ssl/KeyManager;[Ljavax/net/ssl/TrustManager;Ljava/security/SecureRandom;)V
    invoke-virtual {v1}, Ljavax/net/ssl/SSLContext;->getSocketFactory()Ljavax/net/ssl/SSLSocketFactory;
    move-result-object v1
    iget-object v2, p0, Lcom/adriantools/tvcontrol/Conn;->host:Ljava/lang/String;
    iget v3, p0, Lcom/adriantools/tvcontrol/Conn;->port:I
    const/4 v5, 0x1
    invoke-virtual {v1, v0, v2, v3, v5}, Ljavax/net/ssl/SSLSocketFactory;->createSocket(Ljava/net/Socket;Ljava/lang/String;IZ)Ljava/net/Socket;
    move-result-object v0
    check-cast v0, Ljavax/net/ssl/SSLSocket;
    iput-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->sock:Ljava/net/Socket;
    invoke-virtual {v0}, Ljavax/net/ssl/SSLSocket;->startHandshake()V
    invoke-virtual {v0}, Ljavax/net/ssl/SSLSocket;->getSession()Ljavax/net/ssl/SSLSession;
    move-result-object v1
    invoke-interface {v1}, Ljavax/net/ssl/SSLSession;->getPeerCertificates()[Ljava/security/cert/Certificate;
    move-result-object v1
    const/4 v2, 0x0
    aget-object v1, v1, v2
    invoke-virtual {v1}, Ljava/security/cert/Certificate;->getEncoded()[B
    move-result-object v1
    const-string v2, "SHA-256"
    invoke-static {v2}, Ljava/security/MessageDigest;->getInstance(Ljava/lang/String;)Ljava/security/MessageDigest;
    move-result-object v2
    invoke-virtual {v2, v1}, Ljava/security/MessageDigest;->digest([B)[B
    move-result-object v1
    const/4 v2, 0x2
    invoke-static {v1, v2}, Landroid/util/Base64;->encodeToString([BI)Ljava/lang/String;
    move-result-object v4

    :plain
    invoke-virtual {v0}, Ljava/net/Socket;->getOutputStream()Ljava/io/OutputStream;
    move-result-object v1
    iput-object v1, p0, Lcom/adriantools/tvcontrol/Conn;->out:Ljava/io/OutputStream;
    invoke-virtual {v0}, Ljava/net/Socket;->getInputStream()Ljava/io/InputStream;
    move-result-object v5
    const-string v1, "open"
    invoke-virtual {p0, v1, v4}, Lcom/adriantools/tvcontrol/Conn;->post(Ljava/lang/String;Ljava/lang/String;)V
    const/16 v1, 0x4000
    new-array v6, v1, [B

    :loop
    invoke-virtual {v5, v6}, Ljava/io/InputStream;->read([B)I
    move-result v1
    if-lez v1, :try_end
    const/4 v2, 0x0
    const/4 v3, 0x2
    invoke-static {v6, v2, v1, v3}, Landroid/util/Base64;->encodeToString([BIII)Ljava/lang/String;
    move-result-object v2
    const-string v3, "data"
    invoke-virtual {p0, v3, v2}, Lcom/adriantools/tvcontrol/Conn;->post(Ljava/lang/String;Ljava/lang/String;)V
    goto :loop
    :try_end
    .catch Ljava/lang/Exception; {:try_start .. :try_end} :caught
    goto :done

    :caught
    move-exception v0

    :done
    invoke-virtual {p0}, Lcom/adriantools/tvcontrol/Conn;->shut()V
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->bridge:Lcom/adriantools/tvcontrol/Bridge;
    iget-object v0, v0, Lcom/adriantools/tvcontrol/Bridge;->conns:Ljava/util/concurrent/ConcurrentHashMap;
    iget v1, p0, Lcom/adriantools/tvcontrol/Conn;->id:I
    invoke-static {v1}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object v1
    invoke-virtual {v0, v1}, Ljava/util/concurrent/ConcurrentHashMap;->remove(Ljava/lang/Object;)Ljava/lang/Object;
    const-string v0, "close"
    const-string v1, ""
    invoke-virtual {p0, v0, v1}, Lcom/adriantools/tvcontrol/Conn;->post(Ljava/lang/String;Ljava/lang/String;)V
    return-void
.end method

.method send([B)V
    .registers 4
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->out:Ljava/io/OutputStream;
    if-eqz v0, :done
    :try_start
    invoke-virtual {v0, p1}, Ljava/io/OutputStream;->write([B)V
    invoke-virtual {v0}, Ljava/io/OutputStream;->flush()V
    :try_end
    .catch Ljava/lang/Exception; {:try_start .. :try_end} :caught
    goto :done

    :caught
    move-exception v0
    invoke-virtual {p0}, Lcom/adriantools/tvcontrol/Conn;->shut()V

    :done
    return-void
.end method

.method shut()V
    .registers 2
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Conn;->sock:Ljava/net/Socket;
    if-eqz v0, :done
    :try_start
    invoke-virtual {v0}, Ljava/net/Socket;->close()V
    :try_end
    .catch Ljava/lang/Exception; {:try_start .. :try_end} :caught
    goto :done

    :caught
    move-exception v0

    :done
    return-void
.end method

.method post(Ljava/lang/String;Ljava/lang/String;)V
    .registers 7
    new-instance v0, Ljava/lang/StringBuilder;
    const-string v1, "Net.on("
    invoke-direct {v0, v1}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V
    iget v1, p0, Lcom/adriantools/tvcontrol/Conn;->id:I
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;
    const-string v1, ",'"
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v0, p1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    const-string v1, "','"
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v0, p2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    const-string v1, "')"
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v0}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v0
    iget-object v1, p0, Lcom/adriantools/tvcontrol/Conn;->bridge:Lcom/adriantools/tvcontrol/Bridge;
    iget-object v1, v1, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    new-instance v2, Lcom/adriantools/tvcontrol/Js;
    invoke-direct {v2, v1, v0}, Lcom/adriantools/tvcontrol/Js;-><init>(Landroid/webkit/WebView;Ljava/lang/String;)V
    invoke-virtual {v1, v2}, Landroid/webkit/WebView;->post(Ljava/lang/Runnable;)Z
    return-void
.end method
