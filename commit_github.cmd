@echo off
setlocal EnableExtensions

rem ============================================================
rem EDIT HERE 1:
rem Change this path only when you want to push a different repo.
set "DEFAULT_REPO=C:\Users\USER\Documents\GitHub\lazy_paddleocr"

rem EDIT HERE 2:
rem Change this message before double-clicking if needed.
set "DEFAULT_COMMIT_MESSAGE=Update project files"
rem ============================================================

if /I "%~1"=="/?" goto :usage
if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage

set "TARGET_REPO=%DEFAULT_REPO%"
set "COMMIT_MESSAGE=%DEFAULT_COMMIT_MESSAGE%"

if not "%~1"=="" (
    if exist "%~f1\.git\" (
        set "TARGET_REPO=%~f1"
        shift /1
    ) else (
        call :looks_like_path "%~1"
        if not errorlevel 1 (
            if not exist "%~f1\" (
                echo Repository path does not exist:
                echo %~f1
                pause
                exit /b 1
            )

            echo This folder is not a Git repository:
            echo %~f1
            pause
            exit /b 1
        )
    )
)

:collect_message
if "%~1"=="" goto args_done
if defined COMMIT_MESSAGE (
    set "COMMIT_MESSAGE=%COMMIT_MESSAGE% %~1"
) else (
    set "COMMIT_MESSAGE=%~1"
)
shift /1
goto collect_message

:args_done
if not defined TARGET_REPO set "TARGET_REPO=%CD%"
if not defined COMMIT_MESSAGE set "COMMIT_MESSAGE=Update project files"

pushd "%TARGET_REPO%" >nul 2>&1 || (
    echo Failed to enter repository folder:
    echo %TARGET_REPO%
    pause
    exit /b 1
)

where git >nul 2>&1
if errorlevel 1 (
    echo git.exe was not found. Install Git first, then try again.
    goto :fail
)

if not exist ".git" (
    echo This folder is not a Git repository:
    echo %CD%
    goto :fail
)

for /f "usebackq delims=" %%I in (`git branch --show-current`) do set "CURRENT_BRANCH=%%I"
if not defined CURRENT_BRANCH (
    echo Could not determine the current branch.
    goto :fail
)

echo Repository : %CD%
echo Branch     : %CURRENT_BRANCH%
echo Message    : %COMMIT_MESSAGE%
echo.
echo Staging all changes...
git add -A
if errorlevel 1 goto :fail

git diff --cached --quiet --exit-code
if errorlevel 1 goto :has_changes
echo No staged changes to commit.
popd >nul
exit /b 0

:has_changes
echo.
echo Creating commit...
git commit -m "%COMMIT_MESSAGE%"
if errorlevel 1 goto :fail

echo.
echo Pushing to GitHub...
git push origin %CURRENT_BRANCH%
if errorlevel 1 goto :fail

echo.
echo GitHub update completed successfully.
popd >nul
exit /b 0

:fail
echo.
echo GitHub update failed.
popd >nul
pause
exit /b 1

:looks_like_path
set "CANDIDATE=%~1"
if "%CANDIDATE%"=="." exit /b 0
if "%CANDIDATE%"==".." exit /b 0
echo(%CANDIDATE%| findstr /r "[\\/:]" >nul
if errorlevel 1 exit /b 1
exit /b 0

:usage
echo Usage:
echo   commit_github.cmd [repo_path] [commit message]
echo.
echo Double-click mode:
echo   Edit DEFAULT_REPO and DEFAULT_COMMIT_MESSAGE in this file.
echo   Then just double-click commit_github.cmd.
echo.
echo Examples:
echo   commit_github.cmd "Update project files"
echo   commit_github.cmd . "Update project files"
echo   commit_github.cmd "C:\Users\USER\Documents\GitHub\lazy_paddleocr" "Reorganize scripts"
exit /b 0
