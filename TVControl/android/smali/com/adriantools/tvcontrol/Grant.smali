.class final Lcom/adriantools/tvcontrol/Grant;
.super Landroid/webkit/WebChromeClient;

# Only the bundled hub page loads in this WebView, and Android's own camera and mic permissions still apply.

.method constructor <init>()V
    .registers 1
    invoke-direct {p0}, Landroid/webkit/WebChromeClient;-><init>()V
    return-void
.end method

.method public onPermissionRequest(Landroid/webkit/PermissionRequest;)V
    .registers 3
    invoke-virtual {p1}, Landroid/webkit/PermissionRequest;->getResources()[Ljava/lang/String;
    move-result-object v0
    invoke-virtual {p1, v0}, Landroid/webkit/PermissionRequest;->grant([Ljava/lang/String;)V
    return-void
.end method
