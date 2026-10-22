# 事务控制与事件流样本

运行 `python scripts/generate_transaction_fixtures.py` 重建 `transaction_fixture_test.mbt` 与 manifest；`--check` 检查一致性。

36 个样本包含 QUERY/XID、错误布局和 SQL、CRC 错误、post-header 格式变体，以及完整提交/回滚/多语句/连续事务/EOF/更新配对/OFF 事件流。TABLE_MAP 和 ROWS 复用独立生成器的原始数据。

完整流从物理位置 4 开始，重写每个公共头 next_position 并重新计算 CRC；OFF 流只重写头，不添加 CRC。状态机仍按调用者提供的物理偏移检查连续性，而不是信任 next_position。

manifest 记录每个样本的字节数和 SHA-256。样本为事务型 RBR 子集的协议构造，不代表任意 SQL、存储引擎、GTID/XA 或实际数据库日志已经完成集成验证。
