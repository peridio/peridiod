workspace_path = "test/workspace"
File.rm_rf(workspace_path)
File.mkdir(workspace_path)
Application.ensure_all_started(:peridiod)

ExUnit.start()
