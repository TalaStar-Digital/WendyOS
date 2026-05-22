# GPU Access

GPU access is used on NVIDIA Jetson devices for CUDA, ML inference, image processing, DeepStream, PyTorch, TensorRT, and MLX workloads.

```bash
wendy project entitlements add gpu
```

## Device Commands

Show device version and GPU summary:

```bash
wendy device version
```

List GPU hardware capabilities:

```bash
wendy device hardware list --category gpu
```

## Common Pairings

Camera inference:

```bash
wendy project entitlements add camera
wendy project entitlements add gpu
```

Networked inference server:

```bash
wendy project entitlements add gpu
wendy project entitlements add network --mode host
```

## App Configuration

```json
{
  "appId": "com.example.gpu",
  "version": "1.0.0",
  "entitlements": [
    { "type": "gpu" }
  ]
}
```
