require File.dirname(__FILE__) + '/../spec_helper'

describe TaxaController do
  describe "show" do
    render_views
    # not a pretty test. maybe it's time for view tests...?
    it "should use a taxon name for the user's place instead of the default" do
      t = Taxon.make!
      tn1 = TaxonName.make!(:taxon => t, :name => "the default name")
      tn2 = TaxonName.make!(:taxon => t, :name => "the place name")
      p = Place.make!
      PlaceTaxonName.make!(:place => p, :taxon_name => tn2)
      user = User.make!(:place => p)
      sign_in user
      get :show, :id => t.id
      expect(response.body).to be =~ /<h2>.*?#{tn2.name}.*?<\/h2>/m
    end
  end

  describe "merge" do
    it "should redirect on succesfully merging" do
      user = make_curator
      keeper = Taxon.make!
      reject = Taxon.make!
      sign_in user
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(response).to be_redirect
    end

    it "should allow curators to merge taxa they created" do
      curator = make_curator
      sign_in curator
      keeper = Taxon.make!(:creator => curator)
      reject = Taxon.make!(:creator => curator)
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(Taxon.find_by_id(reject.id)).to be_blank
    end

    it "should not allow curators to merge taxa they didn't create" do
      curator = make_curator
      sign_in curator
      keeper = Taxon.make!(:creator => curator)
      reject = Taxon.make!
      Observation.make!(:taxon => reject)
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(Taxon.find_by_id(reject.id)).not_to be_blank
    end

    it "should allow curators to merge synonyms" do
      curator = make_curator
      sign_in curator
      keeper = Taxon.make!(:name => "Foo")
      reject = Taxon.make!(:name => "Foo")
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(Taxon.find_by_id(reject.id)).to be_blank
    end

    it "should not allow curators to merge unsynonymous taxa" do
      curator = make_curator
      sign_in curator
      keeper = Taxon.make!
      reject = Taxon.make!
      Observation.make!(:taxon => reject)
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(Taxon.find_by_id(reject.id)).not_to be_blank
    end

    it "should allow curators to merge taxa without observations" do
      curator = make_curator
      sign_in curator
      keeper = Taxon.make!
      reject = Taxon.make!
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(Taxon.find_by_id(reject.id)).to be_blank
    end

    it "should allow admins to merge anything" do
      curator = make_admin
      sign_in curator
      keeper = Taxon.make!
      reject = Taxon.make!
      post :merge, :id => reject.id, :taxon_id => keeper.id, :commit => "Merge"
      expect(Taxon.find_by_id(reject.id)).to be_blank
    end

    describe "routes" do
      let(:taxon) { Taxon.make! }
      before do
        sign_in make_curator
      end
      it "should accept GET requests" do
        expect(get: "/taxa/#{taxon.to_param}/merge").to be_routable
      end
      it "should accept POST requests" do
        expect(post: "/taxa/#{taxon.to_param}/merge").to be_routable
      end
    end
  end

  describe "destroy" do
    it "should be possible if user did create the record" do
      u = make_curator
      sign_in u
      t = Taxon.make!(:creator => u)
      delete :destroy, :id => t.id
      expect(Taxon.find_by_id(t.id)).to be_blank
    end

    it "should not be possible if user did not create the record" do
      u = make_curator
      sign_in u
      t = Taxon.make!
      delete :destroy, :id => t.id
      expect(Taxon.find_by_id(t.id)).not_to be_blank
    end

    it "should always be possible for admins" do
      u = make_admin
      sign_in u
      t = Taxon.make!
      delete :destroy, :id => t.id
      expect(Taxon.find_by_id(t.id)).to be_blank
    end

    it "should not be possible for taxa inolved in taxon changes" do
      u = make_curator
      t = Taxon.make!(:creator => u)
      ts = make_taxon_swap(:input_taxon => t)
      sign_in u
      delete :destroy, :id => t.id
      expect(Taxon.find_by_id(t.id)).not_to be_blank
    end
  end
  
  describe "update" do
    it "should allow curators to supercede locking" do
      user = make_curator
      sign_in user
      locked_parent = Taxon.make!(:locked => true)
      taxon = Taxon.make!
      put :update, :id => taxon.id, :taxon => {:parent_id => locked_parent.id}
      taxon.reload
      expect(taxon.parent_id).to eq locked_parent.id
    end
  end

  describe "autocomplete" do
    it "should choose exact matches" do
      t = Taxon.make!
      get :autocomplete, format: :json
      expect(assigns(:taxa)).to include t
    end
  end

  describe "observation_photos" do
    it "should include photos from observations" do
      o = make_research_grade_observation
      p = o.photos.first
      get :observation_photos, id: o.taxon_id
      expect(assigns(:photos)).to include p
    end
  end

  describe "graft" do
    it "should graft a taxon" do
      genus = Taxon.make!(name: 'Bartleby')
      species = Taxon.make!(name: 'Bartleby thescrivener')
      expect(species.parent).to be_blank
      u = make_curator
      sign_in u
      expect(patch: "/taxa/#{species.to_param}/graft.json").to be_routable
      patch :graft, id: species.id, format: 'json'
      expect(response).to be_success
      species.reload
      expect(species.parent).to eq genus
    end
  end

end
