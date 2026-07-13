# 抖音极速版商品遍历 v4（SKU / 加购分支 + 可读延迟设置）

适配：iOS 16.6、抖音极速版 39.5.0、TrollFools 裸 dylib 注入。

## 每个商品的动作

### 有“共N款”

1. 进入商品详情。
2. 动态识别并点击 `共N款`。
3. 等待 SKU 弹层。
4. 点击右上角 X 关闭。
5. 点击底部 `专享价 / 抖音商城App专享`。
6. 等待后返回商品列表。

### 没有“共N款”

1. 进入商品详情。
2. 点击底部 `加购`。
3. 等待 SKU 弹层。
4. 点击右上角 X 关闭。
5. 直接返回商品列表，不再点击专享价。

翻页加载慢时会持续等待；识别 `商品已全部展示` 后停止。

## 悬浮按钮

- 单击：开始 / 暂停 / 继续
- 双击：修改延迟和随机抖动
- 长按：停止并重置
- 拖动：移动按钮

延迟设置里的每个数值前面都会直接显示功能名称：

- 详情动作前
- SKU/加购弹层
- 专享价点击后
- 翻页基础
- 翻页最长
- 返回列表后
- 随机抖动

## 推荐延迟

- 详情动作前：2.0 秒
- SKU/加购弹层：1.2～2.0 秒
- 专享价点击后：1.0 秒
- 翻页基础：5.0 秒
- 翻页最长：25 秒
- 返回列表后：1.0 秒
- 随机抖动：1.0～1.5 秒

## 编译

覆盖 GitHub 仓库根目录的：

```text
ProductLooper.m
.github/workflows/build.yml
README.md
```

进入 Actions，运行 `Build DouyinLite ProductLooper v4 Universal dylib`，下载 `DouyinLiteProductLooper-v4-Universal`。

注入前移除旧版 ProductLooper，只保留新生成的 `DouyinLiteProductLooper.dylib`。
