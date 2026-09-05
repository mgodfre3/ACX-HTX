# Model Training — Cell-Antenna Detector

Fine-tune YOLOv8 to detect cellular antennas, publish the trained ONNX to the
sovereign CMK-encrypted ACR for distribution to Arc-AKS clusters on ALDO stamps.

## What this proves

- Model artifact **never touches unencrypted Microsoft storage** — training data on CMK blob, trained weights pushed to CMK ACR
- Same `htx-kek` protects storage (data), disks (compute), and registry (models) — **one sovereign key across the whole ML lifecycle**
- Model distribution to the edge is standard OCI pull — Arc-AKS + ACR Connected Registry does the rest

## Files

| File | Purpose |
|---|---|
| `train_antenna_yolo.py` | Ultralytics YOLOv8 fine-tune + ONNX export + ORAS push to sovereign ACR |
| `train-job.yml` | Azure ML job spec — points at CMK blob dataset, targets `htx-gpu-cluster` compute |
| `environment.yml` | Conda env pinning Ultralytics + ONNX runtime |

## Prereqs (one-time)

1. **GPU compute cluster** attached to the Foundry hub (e.g., `Standard_NC6s_v3`, min 0, max 1). Do this from the Azure ML portal or via the AML SDK — it's a workspace-scoped resource, not part of the `ACX-HTX` Bicep.
2. **Antenna dataset** uploaded to the Foundry hub's storage. Structure follows [Ultralytics YOLO format](https://docs.ultralytics.com/datasets/detect/):
   ```
   antenna/
     images/train/*.jpg
     images/val/*.jpg
     labels/train/*.txt
     labels/val/*.txt
     dataset.yaml
   ```
3. **Data asset** registered against the uploaded blob path so the job can `ro_mount` it.
4. Compute cluster's managed identity gets **AcrPush** on the sovereign ACR:
   ```powershell
   az role assignment create --assignee-object-id <compute-mi-object-id> \
     --role AcrPush --scope <acr-resource-id>
   ```

## Submit

```powershell
$env:HTX_ACR_LOGIN_SERVER = az acr list -g ACX-HTX --query "[0].loginServer" -o tsv
(Get-Content training/train-job.yml) -replace '<populated-by-submit-script>', $env:HTX_ACR_LOGIN_SERVER \
  | Set-Content training/train-job.rendered.yml

az ml job create --file training/train-job.rendered.yml \
  --workspace-name acxhtx-foundry-proj \
  --resource-group ACX-HTX
```

Job publishes to `${ACR_LOGIN_SERVER}/models/htx-antenna-detector:v1` on success.

## Verify CMK on the published image

```powershell
$acr = az acr list -g ACX-HTX --query "[0].name" -o tsv
az acr show --name $acr --query "encryption" -o json
# Expect: keyVaultProperties.keyIdentifier -> https://acxhtx-kv-.../keys/htx-kek/<version>
```

## Next: distribution to ALDO

Once trained and in the sovereign ACR, the model image flows to the edge via
`arc-aks/`:
- **ACR Connected Registry** mirror runs *on-prem* on the ALDO stamp
- Arc-AKS clusters pull from the mirror using their local `htx-kek` for decryption
- Foundry Local loads the ONNX and serves inference — same sovereign key, closed loop
