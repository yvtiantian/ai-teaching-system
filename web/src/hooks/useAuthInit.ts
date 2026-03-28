import { useEffect } from "react";
import {
  extractRoleFromMetadata,
  normalizeUserRole,
  resolveCurrentProfileWithRetry,
} from "@/lib/profile";
import { getSupabaseClient } from "@/lib/supabase";
import { useAuthStore } from "@/store/authStore";

export function useAuthInit() {
  const setUser = useAuthStore((state) => state.setUser);
  const clearUser = useAuthStore((state) => state.clearUser);
  const setAuthInitialized = useAuthStore((state) => state.setAuthInitialized);

  useEffect(() => {
    let mounted = true;
    setAuthInitialized(false);

    const init = async () => {
      try {
        const supabase = getSupabaseClient();
        const { data } = await supabase.auth.getSession();
        const session = data.session;

        if (!mounted) {
          return;
        }

        if (!session?.user) {
          clearUser();
          return;
        }

        const metadataRole = extractRoleFromMetadata(session.user.user_metadata);
        const storedRoleRaw =
          typeof window !== "undefined" ? window.localStorage.getItem("selected-role") : null;
        const storedRole = normalizeUserRole(storedRoleRaw, "student");
        const fallbackRole = metadataRole ?? storedRole;
        const { profile, role } = await resolveCurrentProfileWithRetry(fallbackRole, 2);

        if (!mounted) {
          return;
        }

        if (typeof window !== "undefined") {
          window.localStorage.setItem("selected-role", role);
        }

        setUser({
          id: session.user.id,
          email: profile?.email ?? session.user.email ?? "",
          role,
          displayName: profile?.displayName ?? null,
          avatarUrl: profile?.avatarUrl ?? null,
        });
      } catch {
        if (mounted) {
          clearUser();
        }
      } finally {
        if (mounted) {
          setAuthInitialized(true);
        }
      }
    };

    void init();
    return () => {
      mounted = false;
    };
  }, [clearUser, setAuthInitialized, setUser]);
}
