allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Algunos plugins (p. ej. file_picker) fijan compileSdk 34, pero sus
// dependencias (flutter_plugin_android_lifecycle) exigen 36, y el build falla.
// Forzamos compileSdk 36 en TODOS los módulos Android. Reflexión para no
// depender de AGP en este script raíz.
fun Project.forceCompileSdk36() {
    val androidExt = extensions.findByName("android") ?: return
    runCatching {
        val setter = androidExt.javaClass.methods.firstOrNull { m ->
            m.name == "setCompileSdk" && m.parameterTypes.size == 1
        }
        if (setter != null) {
            setter.invoke(androidExt, 36)
        } else {
            val legacy = androidExt.javaClass.methods.firstOrNull { m ->
                m.name == "compileSdkVersion" &&
                    m.parameterTypes.size == 1 &&
                    m.parameterTypes[0] == Integer.TYPE
            }
            legacy?.invoke(androidExt, 36)
        }
    }
}

subprojects {
    // Como arriba forzamos evaluationDependsOn(":app"), algunos módulos ya están
    // evaluados aquí (no se puede registrar afterEvaluate sobre ellos). Aplicamos
    // ya si está evaluado; si no, lo registramos para cuando lo esté.
    if (state.executed) {
        forceCompileSdk36()
    } else {
        afterEvaluate { forceCompileSdk36() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
