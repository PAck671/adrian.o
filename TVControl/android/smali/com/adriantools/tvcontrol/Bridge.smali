.class public Lcom/adriantools/tvcontrol/Bridge;
.super Ljava/lang/Object;

# Raw sockets and device access for the bundled pages: a WebView can't speak ADB or trust the LG's private certificate.

.field final conns:Ljava/util/concurrent/ConcurrentHashMap;
.field hub:Lcom/adriantools/tvcontrol/HubService;
.field lastApp:Ljava/lang/String;
.field since:J
.field final web:Landroid/webkit/WebView;

.method public constructor <init>(Landroid/webkit/WebView;)V
    .registers 3
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    new-instance v0, Ljava/util/concurrent/ConcurrentHashMap;
    invoke-direct {v0}, Ljava/util/concurrent/ConcurrentHashMap;-><init>()V
    iput-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->conns:Ljava/util/concurrent/ConcurrentHashMap;
    const-string v0, ""
    iput-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->lastApp:Ljava/lang/String;
    return-void
.end method

.method public open(ILjava/lang/String;IZ)V
    .registers 6
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    new-instance v0, Lcom/adriantools/tvcontrol/Conn;
    invoke-direct/range {v0 .. v5}, Lcom/adriantools/tvcontrol/Conn;-><init>(Lcom/adriantools/tvcontrol/Bridge;ILjava/lang/String;IZ)V
    return-void
.end method

.method public write(ILjava/lang/String;)V
    .registers 6
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->conns:Ljava/util/concurrent/ConcurrentHashMap;
    invoke-static {p1}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object v1
    invoke-virtual {v0, v1}, Ljava/util/concurrent/ConcurrentHashMap;->get(Ljava/lang/Object;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Lcom/adriantools/tvcontrol/Conn;
    if-eqz v0, :none
    const/4 v1, 0x2
    invoke-static {p2, v1}, Landroid/util/Base64;->decode(Ljava/lang/String;I)[B
    move-result-object v1
    invoke-virtual {v0, v1}, Lcom/adriantools/tvcontrol/Conn;->send([B)V
    :none
    return-void
.end method

.method public close(I)V
    .registers 4
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->conns:Ljava/util/concurrent/ConcurrentHashMap;
    invoke-static {p1}, Ljava/lang/Integer;->valueOf(I)Ljava/lang/Integer;
    move-result-object p1
    invoke-virtual {v0, p1}, Ljava/util/concurrent/ConcurrentHashMap;->get(Ljava/lang/Object;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Lcom/adriantools/tvcontrol/Conn;
    if-eqz v0, :none
    invoke-virtual {v0}, Lcom/adriantools/tvcontrol/Conn;->shut()V
    :none
    return-void
.end method

.method public listen(I)V
    .registers 5
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    new-instance v0, Ljava/lang/Thread;
    new-instance v1, Lcom/adriantools/tvcontrol/Listener;
    invoke-direct {v1, p0, p1}, Lcom/adriantools/tvcontrol/Listener;-><init>(Lcom/adriantools/tvcontrol/Bridge;I)V
    invoke-direct {v0, v1}, Ljava/lang/Thread;-><init>(Ljava/lang/Runnable;)V
    invoke-virtual {v0}, Ljava/lang/Thread;->start()V
    return-void
.end method

.method public overlay(Z)V
    .registers 5
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->hub:Lcom/adriantools/tvcontrol/HubService;
    if-eqz v0, :none
    new-instance v1, Lcom/adriantools/tvcontrol/Resize;
    invoke-direct {v1, v0, p1}, Lcom/adriantools/tvcontrol/Resize;-><init>(Lcom/adriantools/tvcontrol/HubService;Z)V
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    invoke-virtual {v0, v1}, Landroid/webkit/WebView;->post(Ljava/lang/Runnable;)Z
    :none
    return-void
.end method

.method public tailscale()Ljava/lang/String;
    .registers 3
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    :try_start
    invoke-static {}, Lcom/adriantools/tvcontrol/Listener;->address()Ljava/net/InetAddress;
    move-result-object v0
    if-eqz v0, :none
    invoke-virtual {v0}, Ljava/net/InetAddress;->getHostAddress()Ljava/lang/String;
    move-result-object v0
    :try_end
    .catch Ljava/lang/Exception; {:try_start .. :try_end} :none
    return-object v0

    :none
    const-string v0, ""
    return-object v0
.end method

.method public foreground()Ljava/lang/String;
    .registers 11
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    invoke-virtual {v0}, Landroid/webkit/WebView;->getContext()Landroid/content/Context;
    move-result-object v0
    const-string v1, "usagestats"
    invoke-virtual {v0, v1}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/app/usage/UsageStatsManager;
    invoke-static {}, Ljava/lang/System;->currentTimeMillis()J
    move-result-wide v2
    iget-wide v4, p0, Lcom/adriantools/tvcontrol/Bridge;->since:J
    const-wide/16 v6, 0x0
    cmp-long v1, v4, v6
    if-nez v1, :query
    const-wide/32 v4, 0x5265c00
    sub-long v4, v2, v4

    :query
    invoke-virtual {v0, v4, v5, v2, v3}, Landroid/app/usage/UsageStatsManager;->queryEvents(JJ)Landroid/app/usage/UsageEvents;
    move-result-object v1
    iput-wide v2, p0, Lcom/adriantools/tvcontrol/Bridge;->since:J
    if-eqz v1, :done
    new-instance v6, Landroid/app/usage/UsageEvents$Event;
    invoke-direct {v6}, Landroid/app/usage/UsageEvents$Event;-><init>()V

    :loop
    invoke-virtual {v1}, Landroid/app/usage/UsageEvents;->hasNextEvent()Z
    move-result v7
    if-eqz v7, :done
    invoke-virtual {v1, v6}, Landroid/app/usage/UsageEvents;->getNextEvent(Landroid/app/usage/UsageEvents$Event;)Z
    invoke-virtual {v6}, Landroid/app/usage/UsageEvents$Event;->getEventType()I
    move-result v7
    const/4 v8, 0x1
    if-ne v7, v8, :loop
    invoke-virtual {v6}, Landroid/app/usage/UsageEvents$Event;->getPackageName()Ljava/lang/String;
    move-result-object v7
    iput-object v7, p0, Lcom/adriantools/tvcontrol/Bridge;->lastApp:Ljava/lang/String;
    goto :loop

    :done
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->lastApp:Ljava/lang/String;
    return-object v0
.end method

.method public home()V
    .registers 4
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    new-instance v0, Landroid/content/Intent;
    const-string v1, "android.intent.action.MAIN"
    invoke-direct {v0, v1}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V
    const-string v1, "android.intent.category.HOME"
    invoke-virtual {v0, v1}, Landroid/content/Intent;->addCategory(Ljava/lang/String;)Landroid/content/Intent;
    const/high16 v1, 0x10000000
    invoke-virtual {v0, v1}, Landroid/content/Intent;->addFlags(I)Landroid/content/Intent;
    iget-object v1, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    invoke-virtual {v1}, Landroid/webkit/WebView;->getContext()Landroid/content/Context;
    move-result-object v1
    invoke-virtual {v1, v0}, Landroid/content/Context;->startActivity(Landroid/content/Intent;)V
    return-void
.end method

.method public apps()Ljava/lang/String;
    .registers 8
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    invoke-virtual {v0}, Landroid/webkit/WebView;->getContext()Landroid/content/Context;
    move-result-object v0
    invoke-virtual {v0}, Landroid/content/Context;->getPackageManager()Landroid/content/pm/PackageManager;
    move-result-object v0
    new-instance v1, Landroid/content/Intent;
    const-string v2, "android.intent.action.MAIN"
    invoke-direct {v1, v2}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V
    const-string v2, "android.intent.category.LAUNCHER"
    invoke-virtual {v1, v2}, Landroid/content/Intent;->addCategory(Ljava/lang/String;)Landroid/content/Intent;
    const/4 v2, 0x0
    invoke-virtual {v0, v1, v2}, Landroid/content/pm/PackageManager;->queryIntentActivities(Landroid/content/Intent;I)Ljava/util/List;
    move-result-object v1
    new-instance v2, Lorg/json/JSONArray;
    invoke-direct {v2}, Lorg/json/JSONArray;-><init>()V
    invoke-interface {v1}, Ljava/util/List;->iterator()Ljava/util/Iterator;
    move-result-object v1

    :loop
    invoke-interface {v1}, Ljava/util/Iterator;->hasNext()Z
    move-result v3
    if-eqz v3, :done
    invoke-interface {v1}, Ljava/util/Iterator;->next()Ljava/lang/Object;
    move-result-object v3
    check-cast v3, Landroid/content/pm/ResolveInfo;
    iget-object v4, v3, Landroid/content/pm/ResolveInfo;->activityInfo:Landroid/content/pm/ActivityInfo;
    iget-object v4, v4, Landroid/content/pm/PackageItemInfo;->packageName:Ljava/lang/String;
    invoke-virtual {v2, v4}, Lorg/json/JSONArray;->put(Ljava/lang/Object;)Lorg/json/JSONArray;
    invoke-virtual {v3, v0}, Landroid/content/pm/ResolveInfo;->loadLabel(Landroid/content/pm/PackageManager;)Ljava/lang/CharSequence;
    move-result-object v4
    invoke-interface {v4}, Ljava/lang/CharSequence;->toString()Ljava/lang/String;
    move-result-object v4
    invoke-virtual {v2, v4}, Lorg/json/JSONArray;->put(Ljava/lang/Object;)Lorg/json/JSONArray;
    goto :loop

    :done
    invoke-virtual {v2}, Lorg/json/JSONArray;->toString()Ljava/lang/String;
    move-result-object v0
    return-object v0
.end method

# Camera, mic, overlay, usage access and battery, in that order. 0 means allowed.
.method public granted()Ljava/lang/String;
    .registers 8
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    invoke-virtual {v0}, Landroid/webkit/WebView;->getContext()Landroid/content/Context;
    move-result-object v0
    new-instance v1, Lorg/json/JSONArray;
    invoke-direct {v1}, Lorg/json/JSONArray;-><init>()V
    const-string v2, "android.permission.CAMERA"
    invoke-virtual {v0, v2}, Landroid/content/Context;->checkSelfPermission(Ljava/lang/String;)I
    move-result v2
    invoke-virtual {v1, v2}, Lorg/json/JSONArray;->put(I)Lorg/json/JSONArray;
    const-string v2, "android.permission.RECORD_AUDIO"
    invoke-virtual {v0, v2}, Landroid/content/Context;->checkSelfPermission(Ljava/lang/String;)I
    move-result v2
    invoke-virtual {v1, v2}, Lorg/json/JSONArray;->put(I)Lorg/json/JSONArray;
    invoke-static {v0}, Landroid/provider/Settings;->canDrawOverlays(Landroid/content/Context;)Z
    move-result v2
    xor-int/lit8 v2, v2, 0x1
    invoke-virtual {v1, v2}, Lorg/json/JSONArray;->put(I)Lorg/json/JSONArray;
    const-string v2, "appops"
    invoke-virtual {v0, v2}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v2
    check-cast v2, Landroid/app/AppOpsManager;
    const-string v3, "android:get_usage_stats"
    invoke-static {}, Landroid/os/Process;->myUid()I
    move-result v4
    invoke-virtual {v0}, Landroid/content/Context;->getPackageName()Ljava/lang/String;
    move-result-object v5
    invoke-virtual {v2, v3, v4, v5}, Landroid/app/AppOpsManager;->checkOpNoThrow(Ljava/lang/String;ILjava/lang/String;)I
    move-result v2
    invoke-virtual {v1, v2}, Lorg/json/JSONArray;->put(I)Lorg/json/JSONArray;
    const-string v2, "power"
    invoke-virtual {v0, v2}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v2
    check-cast v2, Landroid/os/PowerManager;
    invoke-virtual {v2, v5}, Landroid/os/PowerManager;->isIgnoringBatteryOptimizations(Ljava/lang/String;)Z
    move-result v2
    xor-int/lit8 v2, v2, 0x1
    invoke-virtual {v1, v2}, Lorg/json/JSONArray;->put(I)Lorg/json/JSONArray;
    invoke-virtual {v1}, Lorg/json/JSONArray;->toString()Ljava/lang/String;
    move-result-object v0
    return-object v0
.end method

# Opens Android's own permission screen, so the person at the Echo makes each choice.
.method public setup(I)V
    .registers 7
    .annotation runtime Landroid/webkit/JavascriptInterface;
    .end annotation
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Bridge;->web:Landroid/webkit/WebView;
    invoke-virtual {v0}, Landroid/webkit/WebView;->getContext()Landroid/content/Context;
    move-result-object v0
    const-string v1, "android.settings.APPLICATION_DETAILS_SETTINGS"
    if-eqz p1, :with_package
    const/4 v2, 0x1
    const-string v1, "android.settings.action.MANAGE_OVERLAY_PERMISSION"
    if-eq p1, v2, :with_package
    const/4 v2, 0x2
    const-string v1, "android.settings.USAGE_ACCESS_SETTINGS"
    if-eq p1, v2, :plain
    const-string v1, "android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"

    :with_package
    new-instance v2, Ljava/lang/StringBuilder;
    const-string v3, "package:"
    invoke-direct {v2, v3}, Ljava/lang/StringBuilder;-><init>(Ljava/lang/String;)V
    invoke-virtual {v0}, Landroid/content/Context;->getPackageName()Ljava/lang/String;
    move-result-object v3
    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v2
    invoke-static {v2}, Landroid/net/Uri;->parse(Ljava/lang/String;)Landroid/net/Uri;
    move-result-object v2
    new-instance v3, Landroid/content/Intent;
    invoke-direct {v3, v1, v2}, Landroid/content/Intent;-><init>(Ljava/lang/String;Landroid/net/Uri;)V
    goto :start

    :plain
    new-instance v3, Landroid/content/Intent;
    invoke-direct {v3, v1}, Landroid/content/Intent;-><init>(Ljava/lang/String;)V

    :start
    invoke-virtual {v0, v3}, Landroid/content/Context;->startActivity(Landroid/content/Intent;)V
    return-void
.end method
