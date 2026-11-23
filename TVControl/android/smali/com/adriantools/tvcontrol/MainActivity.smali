.class public Lcom/adriantools/tvcontrol/MainActivity;
.super Landroid/app/Activity;

.method public constructor <init>()V
    .registers 1
    invoke-direct {p0}, Landroid/app/Activity;-><init>()V
    return-void
.end method

.method protected onCreate(Landroid/os/Bundle;)V
    .registers 6
    invoke-super {p0, p1}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V

    new-instance v0, Landroid/webkit/WebView;
    invoke-direct {v0, p0}, Landroid/webkit/WebView;-><init>(Landroid/content/Context;)V
    const/high16 v1, -0x1000000
    invoke-virtual {v0, v1}, Landroid/webkit/WebView;->setBackgroundColor(I)V

    invoke-virtual {v0}, Landroid/webkit/WebView;->getSettings()Landroid/webkit/WebSettings;
    move-result-object v1
    const/4 v2, 0x1
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setJavaScriptEnabled(Z)V
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setDomStorageEnabled(Z)V
    const/4 v2, 0x0
    invoke-virtual {v1, v2}, Landroid/webkit/WebSettings;->setAllowContentAccess(Z)V

    new-instance v1, Lcom/adriantools/tvcontrol/Bridge;
    invoke-direct {v1, v0}, Lcom/adriantools/tvcontrol/Bridge;-><init>(Landroid/webkit/WebView;)V
    const-string v2, "Native"
    invoke-virtual {v0, v1, v2}, Landroid/webkit/WebView;->addJavascriptInterface(Ljava/lang/Object;Ljava/lang/String;)V

    invoke-virtual {p0, v0}, Lcom/adriantools/tvcontrol/MainActivity;->setContentView(Landroid/view/View;)V
    const-string v1, "file:///android_asset/index.html"
    invoke-virtual {v0, v1}, Landroid/webkit/WebView;->loadUrl(Ljava/lang/String;)V

    const/4 v1, 0x2
    new-array v1, v1, [Ljava/lang/String;
    const-string v2, "android.permission.CAMERA"
    const/4 v3, 0x0
    aput-object v2, v1, v3
    const-string v2, "android.permission.RECORD_AUDIO"
    const/4 v3, 0x1
    aput-object v2, v1, v3
    invoke-virtual {p0, v1, v3}, Lcom/adriantools/tvcontrol/MainActivity;->requestPermissions([Ljava/lang/String;I)V
    return-void
.end method

.method protected onResume()V
    .registers 3
    invoke-super {p0}, Landroid/app/Activity;->onResume()V
    new-instance v0, Landroid/content/Intent;
    const-class v1, Lcom/adriantools/tvcontrol/HubService;
    invoke-direct {v0, p0, v1}, Landroid/content/Intent;-><init>(Landroid/content/Context;Ljava/lang/Class;)V
    invoke-virtual {p0, v0}, Lcom/adriantools/tvcontrol/MainActivity;->startForegroundService(Landroid/content/Intent;)Landroid/content/ComponentName;
    return-void
.end method
