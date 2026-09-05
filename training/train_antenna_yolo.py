"""
YOLOv8 fine-tune job for cellular antenna detection.

Runs on Azure ML Foundry compute (single-GPU cluster). Consumes labeled antenna
imagery from a CMK-encrypted blob dataset in the Foundry project. Publishes the
trained ONNX artifact to the sovereign ACR as a signed OCI image so it can be
distributed to Arc-AKS clusters on ALDO stamps.

Adapted from the MWC demo's cv-inference YOLOv8 pipeline (adaptivecloudlab-mwc26-demo).
"""

from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path

from ultralytics import YOLO


def train(
    dataset_yaml: Path,
    base_weights: str,
    epochs: int,
    imgsz: int,
    batch: int,
    project_dir: Path,
    run_name: str,
) -> Path:
    model = YOLO(base_weights)
    results = model.train(
        data=str(dataset_yaml),
        epochs=epochs,
        imgsz=imgsz,
        batch=batch,
        project=str(project_dir),
        name=run_name,
        device=0,
        exist_ok=True,
    )
    best_pt = Path(results.save_dir) / "weights" / "best.pt"
    if not best_pt.exists():
        raise RuntimeError(f"Training finished but best.pt not found at {best_pt}")
    return best_pt


def export_onnx(best_pt: Path) -> Path:
    model = YOLO(str(best_pt))
    onnx_path = model.export(format="onnx", opset=17, dynamic=True, simplify=True)
    return Path(onnx_path)


def push_to_acr(
    onnx_path: Path,
    acr_login_server: str,
    repo: str,
    tag: str,
) -> str:
    """
    Wrap the ONNX file into a minimal OCI image (via ORAS) and push to CMK-encrypted ACR.

    Requires the training compute's managed identity to have AcrPush on the registry.
    """
    image_ref = f"{acr_login_server}/{repo}:{tag}"
    subprocess.run(
        ["az", "acr", "login", "--name", acr_login_server.split(".")[0]],
        check=True,
    )
    subprocess.run(
        [
            "oras", "push", image_ref,
            f"{onnx_path}:application/vnd.microsoft.azureml.model.onnx",
            "--annotation", f"org.opencontainers.image.title=htx-antenna-detector",
            "--annotation", f"org.opencontainers.image.version={tag}",
        ],
        check=True,
    )
    return image_ref


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-yaml", type=Path, required=True)
    parser.add_argument("--base-weights", default="yolov8n.pt")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--output-dir", type=Path, default=Path("./outputs"))
    parser.add_argument("--run-name", default="htx-antenna-v1")
    parser.add_argument("--acr-login-server", required=True)
    parser.add_argument("--repo", default="models/htx-antenna-detector")
    parser.add_argument("--tag", default=os.environ.get("MODEL_VERSION", "v1"))
    args = parser.parse_args()

    print(f"[1/3] Training YOLOv8 on antenna dataset...")
    best_pt = train(
        args.dataset_yaml, args.base_weights, args.epochs, args.imgsz, args.batch,
        args.output_dir, args.run_name,
    )
    print(f"      best.pt -> {best_pt}")

    print(f"[2/3] Exporting to ONNX (opset 17, dynamic axes)...")
    onnx_path = export_onnx(best_pt)
    print(f"      onnx -> {onnx_path} ({onnx_path.stat().st_size / 1e6:.1f} MB)")

    print(f"[3/3] Pushing to sovereign ACR (CMK-encrypted)...")
    image_ref = push_to_acr(onnx_path, args.acr_login_server, args.repo, args.tag)
    print(f"      published -> {image_ref}")
    print("")
    print(f"Next: Arc-AKS clusters on ALDO stamps pull this image via ACR")
    print(f"Connected Registry mirror, decrypt locally with their KEK, load into")
    print(f"Foundry Local for on-prem inference.")


if __name__ == "__main__":
    main()
