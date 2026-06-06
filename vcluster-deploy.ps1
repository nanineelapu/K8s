# ============================================================
#  vCluster Full Deployment Script
#  - Runs all commands on EC2 via SSH
#  - Deploys nanineelapu/jeevanlink with Volumes
#  - Exposes app on localhost:8080
# ============================================================

$KEY     = "E:\Putty\nkey.pem"
$EC2HOST = "ubuntu@ec2-52-78-84-142.ap-northeast-2.compute.amazonaws.com"
$KENV    = "export KUBECONFIG=/home/ubuntu/.kube/config"

function Run-EC2 {
    param([string]$cmd)
    Write-Host ""
    Write-Host ">> $cmd" -ForegroundColor DarkGray
    ssh -i $KEY -o StrictHostKeyChecking=no $EC2HOST "$KENV && $cmd"
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  JeevanLink vCluster Deployment" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ── STEP 1: Install vCluster CLI on EC2 ──────────────────────
Write-Host ""
Write-Host "[1/7] Installing vCluster on EC2..." -ForegroundColor Yellow
Run-EC2 "curl -sL -o /tmp/vcluster 'https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64' && chmod +x /tmp/vcluster && sudo mv /tmp/vcluster /usr/local/bin/vcluster && vcluster version"

# ── STEP 2: Create vCluster ───────────────────────────────────
Write-Host ""
Write-Host "[2/7] Creating vCluster namespace and cluster..." -ForegroundColor Yellow
Run-EC2 "kubectl create namespace vcluster-jeevanlink --dry-run=client -o yaml | kubectl apply -f -"
Run-EC2 "vcluster create jeevanlink-vcluster --namespace vcluster-jeevanlink --connect=false 2>&1 || echo 'vCluster already exists'"

# ── STEP 3: Wait for vCluster to be ready ────────────────────
Write-Host ""
Write-Host "[3/7] Waiting for vCluster pods to be Running..." -ForegroundColor Yellow
Start-Sleep -Seconds 20
Run-EC2 "kubectl get pods -n vcluster-jeevanlink"

# ── STEP 4: Deploy app with Volumes inside vCluster ──────────
Write-Host ""
Write-Host "[4/7] Deploying app with PV + PVC inside vCluster..." -ForegroundColor Yellow

$YAML = @'
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jeevanlink-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /mnt/jeevanlink-data
  persistentVolumeReclaimPolicy: Retain
  storageClassName: standard
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jeevanlink-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jeevanlink-deployment
  labels:
    app: jeevanlink
spec:
  replicas: 2
  selector:
    matchLabels:
      app: jeevanlink
  template:
    metadata:
      labels:
        app: jeevanlink
    spec:
      containers:
        - name: jeevanlink-container
          image: nanineelapu/jeevanlink:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 80
          volumeMounts:
            - name: jeevanlink-storage
              mountPath: /app/data
      volumes:
        - name: jeevanlink-storage
          persistentVolumeClaim:
            claimName: jeevanlink-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: jeevanlink-service
spec:
  type: NodePort
  selector:
    app: jeevanlink
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080
YAML
'@

$deployCmd = "$KENV && vcluster connect jeevanlink-vcluster --namespace vcluster-jeevanlink --background-proxy && $YAML"
ssh -i $KEY -o StrictHostKeyChecking=no $EC2HOST $deployCmd

# ── STEP 5: Verify deployment ─────────────────────────────────
Write-Host ""
Write-Host "[5/7] Verifying deployment..." -ForegroundColor Yellow
Start-Sleep -Seconds 15
Run-EC2 "vcluster connect jeevanlink-vcluster --namespace vcluster-jeevanlink --background-proxy ; kubectl get pv ; kubectl get pvc ; kubectl get pods -l app=jeevanlink ; kubectl get svc jeevanlink-service"

# ── STEP 6: Port-forward to localhost ────────────────────────
Write-Host ""
Write-Host "[6/7] Starting port-forward → localhost:8080..." -ForegroundColor Yellow
Write-Host "  App will be available at: http://localhost:8080" -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkYellow
Write-Host ""

ssh -i $KEY -o StrictHostKeyChecking=no -L 8080:localhost:8080 $EC2HOST `
    "$KENV && vcluster connect jeevanlink-vcluster --namespace vcluster-jeevanlink --background-proxy && kubectl port-forward svc/jeevanlink-service 8080:80"
