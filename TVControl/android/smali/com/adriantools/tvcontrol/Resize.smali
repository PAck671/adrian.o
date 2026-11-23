.class final Lcom/adriantools/tvcontrol/Resize;
.super Ljava/lang/Object;
.implements Ljava/lang/Runnable;

.field final full:Z
.field final hub:Lcom/adriantools/tvcontrol/HubService;

.method constructor <init>(Lcom/adriantools/tvcontrol/HubService;Z)V
    .registers 3
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    iput-object p1, p0, Lcom/adriantools/tvcontrol/Resize;->hub:Lcom/adriantools/tvcontrol/HubService;
    iput-boolean p2, p0, Lcom/adriantools/tvcontrol/Resize;->full:Z
    return-void
.end method

.method public run()V
    .registers 3
    iget-object v0, p0, Lcom/adriantools/tvcontrol/Resize;->hub:Lcom/adriantools/tvcontrol/HubService;
    iget-boolean v1, p0, Lcom/adriantools/tvcontrol/Resize;->full:Z
    invoke-virtual {v0, v1}, Lcom/adriantools/tvcontrol/HubService;->resize(Z)V
    return-void
.end method
