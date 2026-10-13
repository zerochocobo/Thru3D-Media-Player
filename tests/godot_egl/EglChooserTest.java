import android.os.Build;
import java.lang.reflect.*;
import java.util.*;
import javax.microedition.khronos.egl.*;
import org.godotengine.godot.xr.ovr.OvrConfigChooser;

public class EglChooserTest {
    static class Config extends EGLConfig {}
    static class Display extends EGLDisplay {}
    static int checks = 0;
    static void check(boolean value, String label) {
        checks++;
        if (!value) throw new AssertionError(label);
    }
    static <T> T allocate(Class<T> type) throws Exception {
        Class<?> u = Class.forName("sun.misc.Unsafe");
        Field field = u.getDeclaredField("theUnsafe");
        field.setAccessible(true);
        return type.cast(u.getMethod("allocateInstance", Class.class).invoke(field.get(null), type));
    }
    static class Driver implements InvocationHandler {
        final List<EGLConfig> configs = new ArrayList<>();
        final Map<EGLConfig, Map<Integer, Integer>> values = new IdentityHashMap<>();
        EGLConfig add(int depth, int stencil, int samples, int alpha, int renderable, int surfaces) throws Exception {
            EGLConfig c = allocate(Config.class);
            Map<Integer, Integer> v = new HashMap<>();
            v.put(EGL10.EGL_RED_SIZE, 8); v.put(EGL10.EGL_GREEN_SIZE, 8); v.put(EGL10.EGL_BLUE_SIZE, 8);
            v.put(EGL10.EGL_ALPHA_SIZE, alpha); v.put(EGL10.EGL_DEPTH_SIZE, depth); v.put(EGL10.EGL_STENCIL_SIZE, stencil);
            v.put(EGL10.EGL_SAMPLES, samples); v.put(EGL10.EGL_RENDERABLE_TYPE, renderable); v.put(EGL10.EGL_SURFACE_TYPE, surfaces);
            configs.add(c); values.put(c, v); return c;
        }
        public Object invoke(Object proxy, Method method, Object[] args) {
            if (method.getName().equals("eglGetConfigs")) {
                ((int[]) args[3])[0] = configs.size();
                if (args[1] != null) for (int i = 0; i < configs.size(); i++) ((EGLConfig[]) args[1])[i] = configs.get(i);
                return true;
            }
            if (method.getName().equals("eglGetConfigAttrib")) {
                ((int[]) args[3])[0] = values.get((EGLConfig) args[1]).getOrDefault((Integer) args[2], 0);
                return true;
            }
            throw new AssertionError("Unexpected EGL operation: " + method.getName());
        }
        EGLConfig choose() throws Exception {
            EGL10 egl = (EGL10) Proxy.newProxyInstance(EGL10.class.getClassLoader(), new Class<?>[]{EGL10.class}, this);
            return new OvrConfigChooser().chooseConfig(egl, allocate(Display.class));
        }
    }
    public static void main(String[] args) throws Exception {
        Driver d = new Driver();
        EGLConfig emulator = d.add(24, 8, 0, 8, 0x40, 5);
        check(d.choose() == null, "Physical PICO must keep the original strict chooser");
        Build.MANUFACTURER = "Meta";
        check(d.choose() == null, "Other physical vendors must keep the original strict chooser");
        Build.HARDWARE = "ranchu"; Build.MANUFACTURER = "Pico";
        check(d.choose() == emulator, "PICO emulator may use its depth24/stencil8 config");
        EGLConfig exact = d.add(0, 0, 0, 8, 0x40, 5);
        check(d.choose() == exact, "An exact stock config always wins, including on the emulator");
        Build.HARDWARE = "qcom";
        check(d.choose() == exact, "Physical PICO exact choice remains identical");
        Build.HARDWARE = "ranchu"; Build.MANUFACTURER = "Google";
        Driver other = new Driver(); other.add(24, 8, 0, 8, 0x40, 5);
        check(other.choose() == null, "The fallback is not generalized to other emulators");
        Build.MANUFACTURER = "PICO";
        check(other.choose() == other.configs.get(0), "PICO manufacturer case is handled");
        for (int[] bad : new int[][]{{24,8,2,8,0x40,5}, {24,8,0,0,0x40,5}, {24,8,0,8,4,5}, {24,8,0,8,0x40,1}}) {
            Driver invalid = new Driver(); invalid.add(bad[0],bad[1],bad[2],bad[3],bad[4],bad[5]);
            check(invalid.choose() == null, "MSAA, missing alpha, ES2-only and missing pbuffer stay rejected");
        }
        System.out.println("Godot EGL chooser: " + checks + " checks, 0 failures");
    }
}
