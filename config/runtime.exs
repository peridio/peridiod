import Config

shell =
  System.find_executable("bash") || System.find_executable("zsh") || System.find_execurtable("sh")

System.put_env("SHELL", shell)
