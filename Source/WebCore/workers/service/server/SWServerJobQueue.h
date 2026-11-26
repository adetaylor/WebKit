/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "SWServer.h"
#include "ServiceWorkerJobData.h"
#include "Timer.h"
#include "WorkerFetchResult.h"
#include <wtf/Deque.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class SWServerWorker;
class ServiceWorkerJob;
struct WorkerFetchResult;

class SWIFT_PRIVATE_FILEID("WebCore/SWServerJobQueue.swift") SWServerJobQueue final : public RefCountedAndCanMakeWeakPtr<SWServerJobQueue> {
    WTF_MAKE_TZONE_ALLOCATED(SWServerJobQueue);
public:
    static Ref<SWServerJobQueue> create(SWServer& server, const ServiceWorkerRegistrationKey& key) { return adoptRef(*new SWServerJobQueue(server, key)); }
    SWServerJobQueue(const SWServerRegistration&) = delete;
    ~SWServerJobQueue();

    const ServiceWorkerJobData& firstJob() const LIFETIME_BOUND { return m_jobQueue.first(); }
    const ServiceWorkerJobData& lastJob() const LIFETIME_BOUND { return m_jobQueue.last(); }
    void enqueueJob(ServiceWorkerJobData&& jobData) { m_jobQueue.append(WTF::move(jobData)); }
    size_t size() const { return m_jobQueue.size(); }

    struct FirstJobSnapshot {
        ServiceWorkerJobDataIdentifier identifier;
        ServiceWorkerJobType type;
        SWServerConnectionIdentifier connectionIdentifier;
    };
    ALWAYS_INLINE FirstJobSnapshot firstJobSnapshot() const
    {
        auto& job = m_jobQueue.first();
        return { job.identifier(), job.type, job.connectionIdentifier() };
    }

    void runNextJob();

    void scriptFetchFinished(ServiceWorkerJobDataIdentifier, std::optional<ProcessIdentifier>, WorkerFetchResult);
    void importedScriptsFetchFinished(ServiceWorkerJobDataIdentifier, Vector<std::pair<URL, ScriptBuffer>>, std::optional<ProcessIdentifier>);
    void scriptContextFailedToStart(ServiceWorkerJobDataIdentifier, ServiceWorkerIdentifier, String message);
    void scriptContextStarted(ServiceWorkerJobDataIdentifier, ServiceWorkerIdentifier);
    void didFinishInstall(ServiceWorkerJobDataIdentifier, SWServerWorker&, bool wasSuccessful);
    void didResolveRegistrationPromise();
    void cancelJobsFromConnection(SWServerConnectionIdentifier);
    void cancelJobsFromServiceWorker(ServiceWorkerIdentifier);

    NODELETE bool isCurrentlyProcessingJob(ServiceWorkerJobDataIdentifier) const;

private:
    SWServerJobQueue(SWServer&, const ServiceWorkerRegistrationKey&);

    void jobTimerFired();
    void runNextJobSynchronously();
    void rejectCurrentJob(ExceptionData);
    void finishCurrentJob();

    void runRegisterJob(ServiceWorkerJobData);
    void runUnregisterJob(ServiceWorkerJobData);
    void runUpdateJob(ServiceWorkerJobData);

    void install(SWServerRegistration&, ServiceWorkerIdentifier);

    void removeAllJobsMatching(NOESCAPE const Function<bool(ServiceWorkerJobData&)>&);
    void scriptAndImportedScriptsFetchFinished(ServiceWorkerJobData, SWServerRegistration&);

    SWServer& server() const { return m_server.get(); }

    Deque<ServiceWorkerJobData> m_jobQueue;

    Timer m_jobTimer;
    WeakRef<SWServer> m_server;
    ServiceWorkerRegistrationKey m_registrationKey;
    WorkerFetchResult m_workerFetchResult;
};

} // namespace WebCore
