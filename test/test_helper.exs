workspace_path = "test/workspace"
File.rm_rf(workspace_path)
File.mkdir(workspace_path)

ExUnit.start()
