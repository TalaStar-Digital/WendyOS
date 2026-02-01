import Foundation
import Noora

/// Generates Dockerfiles for Python projects that have requirements.txt but no Dockerfile
struct PythonDockerfileGenerator {

    /// Detected Python framework from requirements.txt
    enum Framework: String, CaseIterable {
        case flask
        case fastapi
        case django
        case gunicorn
        case uvicorn
        case none

        var displayName: String {
            switch self {
            case .flask: return "Flask"
            case .fastapi: return "FastAPI"
            case .django: return "Django"
            case .gunicorn: return "Gunicorn"
            case .uvicorn: return "Uvicorn"
            case .none: return "None"
            }
        }
    }

    /// System packages required by common Python packages
    private static let systemDependencies: [String: [String]] = [
        "psycopg2": ["libpq-dev"],
        "psycopg": ["libpq-dev"],
        "psycopg2-binary": [],  // Binary wheel, no system deps needed
        "pillow": ["libjpeg-dev", "zlib1g-dev", "libpng-dev"],
        "pil": ["libjpeg-dev", "zlib1g-dev", "libpng-dev"],
        "mysqlclient": ["default-libmysqlclient-dev", "pkg-config"],
        "lxml": ["libxml2-dev", "libxslt-dev"],
        "cryptography": ["libffi-dev", "libssl-dev"],
        "cffi": ["libffi-dev"],
        "greenlet": ["gcc"],
        "grpcio": ["gcc"],
        "opencv-python": ["libgl1", "libglib2.0-0"],
        "opencv-python-headless": ["libgl1", "libglib2.0-0"],
    ]

    /// Common entry point filenames in priority order
    private static let commonEntryPoints = [
        "main.py",
        "app.py",
        "__main__.py",
        "manage.py",  // Django
        "wsgi.py",
        "asgi.py",
        "server.py",
        "run.py",
    ]

    let projectPath: String

    init(projectPath: String = FileManager.default.currentDirectoryPath) {
        self.projectPath = projectPath
    }

    // MARK: - Python Version Detection

    /// Detects Python version from project files, returns nil if not found
    func detectPythonVersion() -> String? {
        // 1. Check .python-version file
        if let version = readPythonVersionFile() {
            return normalizeVersion(version)
        }

        // 2. Check pyproject.toml
        if let version = readPyprojectTomlVersion() {
            return normalizeVersion(version)
        }

        // 3. Check runtime.txt (Heroku-style)
        if let version = readRuntimeTxt() {
            return normalizeVersion(version)
        }

        return nil
    }

    /// Returns the Python version to use (detected or default)
    func getPythonVersion() -> String {
        detectPythonVersion() ?? "3.12"
    }

    private func readPythonVersionFile() -> String? {
        let path = "\(projectPath)/.python-version"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readPyprojectTomlVersion() -> String? {
        let path = "\(projectPath)/pyproject.toml"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        // Look for requires-python = ">=3.11" or similar
        // Simple regex-free parsing
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("requires-python") {
                // Extract version from something like: requires-python = ">=3.11"
                if let quoteStart = trimmed.firstIndex(of: "\""),
                    let quoteEnd = trimmed.lastIndex(of: "\""),
                    quoteStart < quoteEnd
                {
                    let versionSpec = String(trimmed[trimmed.index(after: quoteStart)..<quoteEnd])
                    // Extract just the version number
                    return extractVersionNumber(from: versionSpec)
                }
            }
        }

        return nil
    }

    private func readRuntimeTxt() -> String? {
        let path = "\(projectPath)/runtime.txt"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        // Format: python-3.11.4
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("python-") {
            return String(trimmed.dropFirst("python-".count))
        }
        return nil
    }

    /// Extracts version number from version specifier like ">=3.11", "~=3.10", "==3.12.1"
    private func extractVersionNumber(from spec: String) -> String? {
        var version = spec
        // Remove common prefixes
        for prefix in [">=", "<=", "~=", "==", ">", "<", "^"] {
            if version.hasPrefix(prefix) {
                version = String(version.dropFirst(prefix.count))
                break
            }
        }
        // Remove any trailing specifiers (e.g., ",<4.0")
        if let commaIndex = version.firstIndex(of: ",") {
            version = String(version[..<commaIndex])
        }
        return version.trimmingCharacters(in: .whitespaces)
    }

    /// Normalizes version to major.minor format for Docker image tag
    private func normalizeVersion(_ version: String) -> String {
        let parts = version.components(separatedBy: ".")
        if parts.count >= 2 {
            return "\(parts[0]).\(parts[1])"
        }
        return version
    }

    // MARK: - Entry Point Detection

    /// Detects the entry point file for the Python application
    func detectEntryPoint() -> String? {
        let fileManager = FileManager.default

        // Check common entry points in priority order
        for entryPoint in Self.commonEntryPoints {
            let path = "\(projectPath)/\(entryPoint)"
            if fileManager.fileExists(atPath: path) {
                return entryPoint
            }
        }

        return nil
    }

    /// Returns all Python files in the project root (for user selection)
    func listPythonFiles() -> [String] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: projectPath) else {
            return []
        }

        return
            contents
            .filter { $0.hasSuffix(".py") && !$0.hasPrefix("_") && $0 != "__init__.py" }
            .sorted()
    }

    /// Prompts user to select an entry point if auto-detection fails
    func promptForEntryPoint(autoAccept: Bool) -> String? {
        let pythonFiles = listPythonFiles()

        if pythonFiles.isEmpty {
            return nil
        }

        if pythonFiles.count == 1 {
            return pythonFiles[0]
        }

        if autoAccept {
            // In auto-accept mode, use first available file
            return pythonFiles.first
        }

        // Let user choose
        return Noora().singleChoicePrompt(
            title: "Select entry point",
            question: "Which Python file is the main entry point?",
            options: pythonFiles
        )
    }

    // MARK: - Framework Detection

    /// Detects the web framework from requirements.txt
    func detectFramework() -> Framework {
        guard let requirements = readRequirements() else {
            return .none
        }

        let lowercased = requirements.lowercased()

        // Check in order of specificity
        if lowercased.contains("fastapi") {
            return .fastapi
        }
        if lowercased.contains("django") {
            return .django
        }
        if lowercased.contains("flask") {
            return .flask
        }
        if lowercased.contains("uvicorn") {
            return .uvicorn
        }
        if lowercased.contains("gunicorn") {
            return .gunicorn
        }

        return .none
    }

    /// Parses requirements.txt and returns package names
    func parseRequirements() -> [String] {
        guard let content = readRequirements() else {
            return []
        }

        var packages: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Skip -r, -e, and other flags
            if trimmed.hasPrefix("-") {
                continue
            }

            // Extract package name (before any version specifier)
            var packageName = trimmed
            for separator in [">=", "<=", "~=", "==", ">", "<", "[", ";"] {
                if let index = packageName.range(of: separator) {
                    packageName = String(packageName[..<index.lowerBound])
                }
            }

            packages.append(packageName.lowercased().trimmingCharacters(in: .whitespaces))
        }

        return packages
    }

    private func readRequirements() -> String? {
        let path = "\(projectPath)/requirements.txt"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - System Dependencies

    /// Detects required system packages based on Python dependencies
    func detectSystemDependencies() -> [String] {
        let packages = parseRequirements()
        var systemDeps = Set<String>()

        for package in packages {
            if let deps = Self.systemDependencies[package] {
                for dep in deps {
                    systemDeps.insert(dep)
                }
            }
        }

        return systemDeps.sorted()
    }

    // MARK: - Dockerfile Generation

    /// Generates the CMD instruction based on detected framework and entry point
    func generateCmd(framework: Framework, entryPoint: String) -> String {
        switch framework {
        case .fastapi:
            // Detect the app variable name (commonly "app" in main.py or app.py)
            let module = entryPoint.replacingOccurrences(of: ".py", with: "")
            return #"CMD ["uvicorn", "\#(module):app", "--host", "0.0.0.0", "--port", "8000"]"#

        case .django:
            return #"CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]"#

        case .flask:
            let module = entryPoint.replacingOccurrences(of: ".py", with: "")
            return
                #"CMD ["flask", "--app", "\#(module)", "run", "--host", "0.0.0.0", "--port", "8000"]"#

        case .gunicorn:
            let module = entryPoint.replacingOccurrences(of: ".py", with: "")
            return #"CMD ["gunicorn", "--bind", "0.0.0.0:8000", "\#(module):app"]"#

        case .uvicorn:
            let module = entryPoint.replacingOccurrences(of: ".py", with: "")
            return #"CMD ["uvicorn", "\#(module):app", "--host", "0.0.0.0", "--port", "8000"]"#

        case .none:
            return #"CMD ["python", "\#(entryPoint)"]"#
        }
    }

    /// Generates a complete Dockerfile for the Python project
    func generateDockerfile(entryPoint: String) -> String {
        let pythonVersion = getPythonVersion()
        let framework = detectFramework()
        let systemDeps = detectSystemDependencies()
        let cmd = generateCmd(framework: framework, entryPoint: entryPoint)

        var dockerfile = """
            # Generated by wendy CLI
            FROM python:\(pythonVersion)

            WORKDIR /app

            """

        // Add system dependencies if needed
        if !systemDeps.isEmpty {
            dockerfile += """
                # Install system dependencies required by Python packages
                RUN apt-get update && apt-get install -y --no-install-recommends \\
                    \(systemDeps.joined(separator: " \\\n    ")) \\
                    && rm -rf /var/lib/apt/lists/*

                """
        }

        dockerfile += """
            # Install Python dependencies
            COPY requirements.txt .
            RUN pip install --no-cache-dir -r requirements.txt

            # Copy application code
            COPY . .

            # Expose the default port
            EXPOSE 8000

            # Run the application
            \(cmd)
            """

        return dockerfile
    }

    /// Writes the generated Dockerfile to the project directory
    func writeDockerfile(entryPoint: String) throws {
        let content = generateDockerfile(entryPoint: entryPoint)
        let path = "\(projectPath)/Dockerfile"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
