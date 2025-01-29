Application.stop(:peridiod)
workspace_path = "test/workspace"
File.rm_rf(workspace_path)
File.mkdir(workspace_path)
Application.start(:peridiod)

ExUnit.start()
