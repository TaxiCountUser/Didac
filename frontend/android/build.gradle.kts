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
// Forzamos compileSdk 36 en TODOS los módulos Android. Usamos reflexión para no
// necesitar el plugin de Android en el classpath de este script raíz.
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android") ?: return@afterEvaluate
        runCatching {
            // AGP 8: propiedad compileSdk (setCompileSdk(Integer)).
            val setter = androidExt.javaClass.methods.firstOrNull { m ->
                m.name == "setCompileSdk" && m.parameterTypes.size == 1
            }
            if (setter != null) {
                setter.invoke(androidExt, 36)
            } else {
                // Fallback: compileSdkVersion(int) (API antigua).
                val legacy = androidExt.javaClass.methods.firstOrNull { m ->
                    m.name == "compileSdkVersion" &&
                        m.parameterTypes.size == 1 &&
                        m.parameterTypes[0] == Integer.TYPE
                }
                legacy?.invoke(androidExt, 36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
