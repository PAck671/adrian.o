.class public Lcom/adriantools/tvcontrol/HubService;
.super Landroid/app/Service;

# Keeps the hub page running with no laptop and no app open. Its window is 1x1 until a call or notice needs the screen.

.field attached:Z
.field lock:Landroid/os/PowerManager$WakeLock;
.field params:Landroid/view/WindowManager$LayoutParams;
.field web:Landroid/webkit/WebView;

.method public constructor <init>()V
    .registers 1
    invoke-direct {p0}, Landroid/app/Service;-><init>()V
    return-void
.end method

.method public onBind(Landroid/content/Intent;)Landroid/os/IBinder;
    .registers 3
    const/4 v0, 0x0
    return-object v0
.end method

.method public onCreate()V
    .registers 7
    invoke-super {p0}, Landroid/app/Service;->onCreate()V

    const-string v0, "notification"
    invoke-virtual {p0, v0}, Lcom/adriantools/tvcontrol/HubService;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/app/NotificationManager;
    new-instance v1, Landroid/app/NotificationChannel;
    const-string v2, "hub"
    const-string v3, "TV Control hub"
    const/4 v4, 0x2
    invoke-direct {v1, v2, v3, v4}, Landroid/app/NotificationChannel;-><init>(Ljava/lang/String;Ljava/lang/CharSequence;I)V
    invoke-virtual {v0, v1}, Landroid/app/NotificationManager;->createNotificationChannel(Landroid/app/NotificationChannel;)V

    new-instance v0, Landroid/app/Notification$Builder;
    invoke-direct {v0, p0, v2}, Landroid/app/Notification$Builder;-><init>(Landroid/content/Context;Ljava/lang/String;)V
    invoke-virtual {v0, v3}, Landroid/app/Notification$Builder;->setContentTitle(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;
    const-string v1, "Ready for calls and app limits"
    invoke-virtual {v0, v1}, Landroid/app/Notification$Builder;->setContentText(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;
    invoke-virtual {p0}, Lcom/adriantools/tvcontrol/HubService;->getApplicationInfo()Landroid/content/pm/ApplicationInfo;
    move-result-object v1
    iget v1, v1, Landroid/content/pm/ApplicationInfo;->icon:I
    invoke-virtual {v0, v1}, Landroid/app/Notification$Builder;->setSmallIcon(I)Landroid/app/Notification$Builder;
    invoke-virtual {v0}, Landroid/app/Notification$Builder;->build()Landroid/app/Notification;
    move-result-object v0
    const/4 v1, 0x1
    invoke-virtual {p0, v1, v0}, Lcom/adriantools/tvcontrol/HubService;->startForeground(ILandroid/app/Notification;)V

    const-string v0, "power"
    invoke-virtual {p0, v0}, Lcom/adriantools/tvcontrol/HubService;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/os/PowerManager;
    const/4 v1, 0x1
    const-string v2, "tvcontrol:hub"
    invoke-virtual {v0, v1, v2}, Landroid/os/PowerManager;->newWakeLock(ILjava/lang/String;)Landroid/os/PowerManager$WakeLock;
    move-result-object v0
    iput-object v0, p0, Lcom/adriantools/tvcontrol/HubService;->lock:Landroid/os/PowerManager$WakeLock;
    invoke-virtual {v0}, Landroid/os/PowerManager$WakeLock;->acquire()V

    new-instance v0, Landroid/webkit/WebView;
    invoke-direct {v0, p0}, Landroid/webkit/WebView;-><init>(Landroid/content/Context;)V
    iput-object v0, p0, Lcom/adriantools/tvcontrol/HubService;->web:Landroid/webkit/WebView;
    const/4 v1, 0x0
    invoke-virtual {v0, v1}, Landroid/webkit/WebView;->setBackgroundColor(I)V
    invoke-virtual {v0}, Landroid/webkit/WebView;->getSettings()Landroid/webkit/WebSettings;
    move-result-object v1
    const/4 v2, 0x1
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setJavaScriptEnabled(Z)V
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setDomStorageEnabled(Z)V
    const/4 v2, 0x0
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setAllowContentAccess(Z)V
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setMediaPlaybackRequiresUserGesture(Z)V
    new-instance v1, Lcom/adriantools/tvcontrol/Grant;
    invoke-direct {v1}, Lcom/adriantools/tvcontrol/Grant;-><init>()V
    invoke-virtual {v0, v1}, Landroid/webkit/WebView;->setWebChromeClient(Landroid/webkit/WebChromeClient;)V
    new-instance v1, Lcom/adriantools/tvcontrol/Bridge;
    invoke-direct {v1, v0}, Lcom/adriantools/tvcontrol/Bridge;-><init>(Landroid/webkit/WebView;)V
    iput-object p0, v1, Lcom/adriantools/tvcontrol/Bridge;->hub:Lcom/adriantools/tvcontrol/HubService;
    const-string v2, "Native"
    invoke-virtual {v0, v1, v2}, Landroid/webkit/WebView;->addJavascriptInterface(Ljava/lang/Object;Ljava/lang/String;)V
    invoke-virtual {p0}, Lcom/adriantools/tvcontrol/HubService;->attach()V
    const-string v1, "file:///android_asset/hub.html"
    invoke-virtual {v0, v1}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V
    return-void
.end method

.method public onStartCommand(Landroid/content/Intent;II)I
    .registers 5
    invoke-virtual {p0}, Lcom/adriantools/tvcontrol/HubService;->attach()V
    const/4 v0, 0x1
    return v0
.end method

.method attach()V
    .registers 8
    iget-boolean v0, p0, Lcom/adriantools/tvcontrol/HubService;->attached:Z
    if-nez v0, :done
    invoke-static {p0}, Landroid/provider/Settings;->canDrawOverlays(Landroid/content/Context;)Z
    move-result v0
    if-eqz v0, :done
    new-instance v0, Landroid/view/WindowManager$LayoutParams;
    const/4 v1, 0x1
    const/4 v2, 0x1
    const/16 v3, 0x7f6
    const/16 v4, 0x18
    const/4 v5, -0x3
    invoke-direct/range {v0 .. v5}, Landroid/view/WindowManager$LayoutParams;-><init>(IIIII)V
    const/16 v1, 0x33
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->gravity:I
    iput-object v0, p0, Lcom/adriantools/tvcontrol/HubService;->params:Landroid/view/WindowManager$LayoutParams;
    const-string v1, "window"
    invoke-virtual {p0, v1}, Lcom/adriantools/tvcontrol/HubService;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v1
    check-cast v1, Landroid/view/WindowManager;
    iget-object v2, p0, Lcom/adriantools/tvcontrol/HubService;->web:Landroid/webkit/WebView;
    invoke-interface {v1, v2, v0}, Landroid/view/ViewManager;->addView(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V
    const/4 v0, 0x1
    iput-boolean v0, p0, Lcom/adriantools/tvcontrol/HubService;->attached:Z
    :done
    return-void
.end method

.method resize(Z)V
    .registers 7
    iget-object v0, p0, Lcom/adriantools/tvcontrol/HubService;->params:Landroid/view/WindowManager$LayoutParams;
    if-eqz v0, :done
    if-eqz p1, :small
    const/4 v1, -0x1
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->width:I
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->height:I
    const v1, 0x200080
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->flags:I
    const-string v1, "power"
    invoke-virtual {p0, v1}, Lcom/adriantools/tvcontrol/HubService;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v1
    check-cast v1, Landroid/os/PowerManager;
    const v2, 0x1000000a
    const-string v3, "tvcontrol:call"
    invoke-virtual {v1, v2, v3}, Landroid/os/PowerManager;->newWakeLock(ILjava/lang/String;)Landroid/os/PowerManager$WakeLock;
    move-result-object v1
    const-wide/16 v2, 0x2710
    invoke-virtual {v1, v2, v3}, Landroid/os/PowerManager$WakeLock;->acquire(J)V
    goto :apply

    :small
    const/4 v1, 0x1
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->width:I
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->height:I
    const/16 v1, 0x18
    iput v1, v0, Landroid/view/WindowManager$LayoutParams;->flags:I

    :apply
    const-string v1, "window"
    invoke-virtual {p0, v1}, Lcom/adriantools/tvcontrol/HubService;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v1
    check-cast v1, Landroid/view/WindowManager;
    iget-object v2, p0, Lcom/adriantools/tvcontrol/HubService;->web:Landroid/webkit/WebView;
    invoke-interface {v1, v2, v0}, Landroid/view/ViewManager;->updateViewLayout(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V
    :done
    return-void
.end method
