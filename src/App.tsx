import { BrowserRouter, Route, Routes } from "react-router-dom";
import { SessionProvider } from "./auth/SessionProvider";
import { IdleTimeoutGuard } from "./auth/IdleTimeoutGuard";
import { RecoverySessionBoundary } from "./auth/RecoverySessionBoundary";
import {
  RequireAccount, RequireAdministrator, RequireCouncilSecretary, RequireLandOfficer,
  RequireRegistryClerk, RequireResident, RequireStaff, RequireStaffOrResident,
} from "./components/guards";
import { isConfigured } from "./lib/supabaseClient";
import { Landing } from "./pages/Landing";
import { SignIn } from "./pages/SignIn";
import { SetPassword } from "./pages/SetPassword";
import { ForgotPassword } from "./pages/ForgotPassword";
import { ResetPassword } from "./pages/ResetPassword";
import { AdminDashboard } from "./pages/AdminDashboard";
import { StaffAccounts } from "./pages/StaffAccounts";
import { CreateStaffAccount } from "./pages/CreateStaffAccount";
import { StaffHome } from "./pages/StaffHome";
import { NoAccess } from "./pages/NoAccess";
import { RegistryDashboard } from "./pages/registry/RegistryDashboard";
import { Residents } from "./pages/registry/Residents";
import { ResidentDetail } from "./pages/registry/ResidentDetail";
import { ResidentForm } from "./pages/registry/ResidentForm";
import { Households } from "./pages/registry/Households";
import { HouseholdDetail } from "./pages/registry/HouseholdDetail";
import { FamilyLineage } from "./pages/registry/FamilyLineage";
import { ResidentRequests } from "./pages/registry/ResidentRequests";
import { ResidentRequestReview } from "./pages/registry/ResidentRequestReview";
import { Register } from "./pages/resident/Register";
import { ResidentPortalPage } from "./pages/resident/ResidentPortal";
import { LandDashboard } from "./pages/land/LandDashboard";
import { LandApplications } from "./pages/land/LandApplications";
import { LandApplicationReview } from "./pages/land/LandApplicationReview";
import { LandSites } from "./pages/land/LandSites";
import { LandSiteHistory } from "./pages/land/LandSiteHistory";
import { LandAllocations } from "./pages/land/LandAllocations";
import { LandPtos } from "./pages/land/LandPtos";
import { LandRenewals } from "./pages/land/LandRenewals";
import { LandSuccession } from "./pages/land/LandSuccession";
import { PtoDocumentPage } from "./pages/land/PtoDocumentPage";
import { VerifyPto } from "./pages/land/VerifyPto";
import { SecretaryDashboard } from "./pages/secretary/SecretaryDashboard";
import { Meetings } from "./pages/secretary/Meetings";
import { MeetingDetail } from "./pages/secretary/MeetingDetail";
import { Resolutions } from "./pages/secretary/Resolutions";
import { Projects } from "./pages/secretary/Projects";
import { ProjectDetail } from "./pages/secretary/ProjectDetail";
import { Communications } from "./pages/secretary/Communications";
import { SendCommunication } from "./pages/secretary/SendCommunication";
import { Notifications } from "./pages/Notifications";
import { Messages } from "./pages/messages/Messages";
import { MessageDetail } from "./pages/messages/MessageDetail";
import { ComposeMessage } from "./pages/messages/ComposeMessage";
import { AuditTrail } from "./pages/admin/AuditTrail";
import { AuditDetail } from "./pages/admin/AuditDetail";
import { TransferAdministrator } from "./pages/admin/TransferAdministrator";
import { NotFound } from "./pages/NotFound";
import { Notice } from "./components/ui";

function NotConfigured() {
  return (
    <div className="centre">
      <div className="centre-card narrow">
        <h1 style={{ fontSize: 22 }}>TAMS is not connected yet</h1>
        <div style={{ marginTop: 16 }}>
          <Notice kind="info">
            Copy <code>.env.example</code> to <code>.env</code> and fill in{" "}
            <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> from your
            Supabase project, then restart the development server.
          </Notice>
        </div>
      </div>
    </div>
  );
}

export default function App() {
  if (!isConfigured) return <NotConfigured />;

  return (
    <SessionProvider>
      <BrowserRouter>
        <IdleTimeoutGuard />
        <RecoverySessionBoundary>
          <Routes>
          <Route path="/" element={<Landing />} />
          <Route path="/auth" element={<SignIn />} />
          <Route path="/set-password" element={<SetPassword />} />
          <Route path="/forgot-password" element={<ForgotPassword />} />
          <Route path="/reset-password" element={<ResetPassword />} />
          <Route path="/no-access" element={<NoAccess />} />
          <Route path="/register" element={<Register />} />

          {/* Anybody holding a printed permission may check it. */}
          <Route path="/verify/pto" element={<VerifyPto />} />
          <Route path="/verify/pto/:token" element={<VerifyPto />} />

          {/* Any signed-in resident, whatever their verification */}
          <Route path="/resident" element={<RequireResident><ResidentPortalPage /></RequireResident>} />
          <Route path="/resident/notifications" element={<RequireResident><Notifications /></RequireResident>} />

          {/* Any active staff member */}
          <Route path="/home" element={<RequireStaff><StaffHome /></RequireStaff>} />
          <Route path="/messages" element={<RequireStaff><Messages /></RequireStaff>} />
          <Route path="/messages/new" element={<RequireStaff><ComposeMessage /></RequireStaff>} />
          <Route path="/messages/:messageId" element={<RequireStaff><MessageDetail /></RequireStaff>} />

          {/* Anybody signed in reads their own notifications, and only their own */}
          <Route path="/notifications" element={<RequireAccount><Notifications /></RequireAccount>} />

          {/* The active Council Administrator only */}
          <Route path="/dashboard" element={<RequireAdministrator><AdminDashboard /></RequireAdministrator>} />
          <Route path="/staff" element={<RequireAdministrator><StaffAccounts /></RequireAdministrator>} />
          <Route path="/staff/new" element={<RequireAdministrator><CreateStaffAccount /></RequireAdministrator>} />
          <Route path="/admin/audit" element={<RequireAdministrator><AuditTrail /></RequireAdministrator>} />
          <Route path="/admin/audit/:auditId" element={<RequireAdministrator><AuditDetail /></RequireAdministrator>} />
          <Route path="/admin/transfer" element={<RequireAdministrator><TransferAdministrator /></RequireAdministrator>} />

          {/* The active Registry Clerk only */}
          <Route path="/registry" element={<RequireRegistryClerk><RegistryDashboard /></RequireRegistryClerk>} />
          <Route path="/registry/residents" element={<RequireRegistryClerk><Residents /></RequireRegistryClerk>} />
          <Route path="/registry/residents/new" element={<RequireRegistryClerk><ResidentForm mode="create" /></RequireRegistryClerk>} />
          <Route path="/registry/residents/:residentId" element={<RequireRegistryClerk><ResidentDetail /></RequireRegistryClerk>} />
          <Route path="/registry/residents/:residentId/edit" element={<RequireRegistryClerk><ResidentForm mode="update" /></RequireRegistryClerk>} />
          <Route path="/registry/households" element={<RequireRegistryClerk><Households /></RequireRegistryClerk>} />
          <Route path="/registry/households/:householdId" element={<RequireRegistryClerk><HouseholdDetail /></RequireRegistryClerk>} />
          <Route path="/registry/lineage" element={<RequireRegistryClerk><FamilyLineage /></RequireRegistryClerk>} />
          <Route path="/registry/lineage/:residentId" element={<RequireRegistryClerk><FamilyLineage /></RequireRegistryClerk>} />
          <Route path="/registry/resident-accounts" element={<RequireRegistryClerk><ResidentRequests /></RequireRegistryClerk>} />
          <Route path="/registry/resident-accounts/:requestId" element={<RequireRegistryClerk><ResidentRequestReview /></RequireRegistryClerk>} />

          {/* The active Land Officer only */}
          <Route path="/land" element={<RequireLandOfficer><LandDashboard /></RequireLandOfficer>} />
          <Route path="/land/applications" element={<RequireLandOfficer><LandApplications /></RequireLandOfficer>} />
          <Route path="/land/applications/:applicationId" element={<RequireLandOfficer><LandApplicationReview /></RequireLandOfficer>} />
          <Route path="/land/sites" element={<RequireLandOfficer><LandSites /></RequireLandOfficer>} />
          <Route path="/land/sites/:siteId" element={<RequireLandOfficer><LandSiteHistory /></RequireLandOfficer>} />
          <Route path="/land/allocations" element={<RequireLandOfficer><LandAllocations /></RequireLandOfficer>} />
          <Route path="/land/ptos" element={<RequireLandOfficer><LandPtos /></RequireLandOfficer>} />
          <Route path="/land/renewals" element={<RequireLandOfficer><LandRenewals /></RequireLandOfficer>} />
          <Route path="/land/succession" element={<RequireLandOfficer><LandSuccession /></RequireLandOfficer>} />

          {/* The active Council Secretary only */}
          <Route path="/secretary" element={<RequireCouncilSecretary><SecretaryDashboard /></RequireCouncilSecretary>} />
          <Route path="/secretary/meetings" element={<RequireCouncilSecretary><Meetings /></RequireCouncilSecretary>} />
          <Route path="/secretary/meetings/:meetingId" element={<RequireCouncilSecretary><MeetingDetail /></RequireCouncilSecretary>} />
          <Route path="/secretary/resolutions" element={<RequireCouncilSecretary><Resolutions /></RequireCouncilSecretary>} />
          <Route path="/secretary/projects" element={<RequireCouncilSecretary><Projects /></RequireCouncilSecretary>} />
          <Route path="/secretary/projects/:projectId" element={<RequireCouncilSecretary><ProjectDetail /></RequireCouncilSecretary>} />
          <Route path="/secretary/communications" element={<RequireCouncilSecretary><Communications /></RequireCouncilSecretary>} />
          <Route path="/secretary/communications/new" element={<RequireCouncilSecretary><SendCommunication /></RequireCouncilSecretary>} />

          {/* The permission document itself. Who may open which one is
              decided in the database, not here: a resident sees their
              own, the Land Officer sees any. */}
          <Route path="/pto/:ptoId" element={<RequireStaffOrResident><PtoDocumentPage /></RequireStaffOrResident>} />

          {/* Anything else is a page that does not exist — and still has
              a way home, chosen for whoever is asking. */}
          <Route path="*" element={<NotFound />} />
          </Routes>
        </RecoverySessionBoundary>
      </BrowserRouter>
    </SessionProvider>
  );
}
